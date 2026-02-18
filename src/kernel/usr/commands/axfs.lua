--
-- /usr/commands/axfs.lua
-- AXFS multi-tool: partition, format, mount, read/write
--
-- Usage:
--   axfs scan                              List block devices
--   axfs init <dev>                        Write empty RDB
--   axfs parts <dev>                       Show partitions
--   axfs addpart <dev> <name> <sectors>    Create partition
--   axfs rmpart <dev> <index>              Remove partition
--   axfs format <dev> <part#> [label]      Format with AXFS
--   axfs info <dev> <part#>                FS info
--   axfs ls <dev> <part#> [path]           List directory
--   axfs cat <dev> <part#> <path>          Read file
--   axfs write <dev> <part#> <path> <data> Write file
--   axfs mkdir <dev> <part#> <path>        Create directory
--   axfs rm <dev> <part#> <path>           Remove file/dir
--   axfs stat <dev> <part#> <path>         Inode info
--   axfs import <dev> <part#> <src> <dst>  Managed FS → AXFS
--   axfs export <dev> <part#> <src> <dst>  AXFS → Managed FS
--

local fs = require("filesystem")
local AX = require("axfs_core")
local RDB = require("rdb")
local B = require("bpack")
local args = env.ARGS or {}

local C = {R="\27[37m",G="\27[32m",Y="\27[33m",C="\27[36m",E="\27[31m",D="\27[90m"}

local function die(s) print(C.E .. "Error: " .. C.R .. s); return end
local function ok(s)  print(C.G .. "[OK] " .. C.R .. s) end

-- Open block device and return tDisk wrapper
local function openDev(sPath)
  local h = fs.open(sPath, "r")
  if not h then return nil, "Cannot open " .. sPath end
  local tD, sE = AX.wrapDevice(h, fs, 0)
  if not tD then fs.close(h); return nil, sE end
  tD._handle = h
  tD._close = function() fs.close(h) end
  return tD
end

-- Open device + partition → tDisk scoped to partition
local function openPart(sPath, nPart)
  local tD, sE = openDev(sPath)
  if not tD then return nil, nil, sE end
  local tRdb, sRE = RDB.read(tD)
  if not tRdb then tD._close(); return nil, nil, sRE end
  nPart = tonumber(nPart)
  if not nPart or not tRdb.partitions[nPart+1] then
    tD._close(); return nil, nil, "Partition " .. tostring(nPart) .. " not found"
  end
  local p = tRdb.partitions[nPart+1]
  -- re-open wrapped to partition boundaries
  local h2 = fs.open(sPath, "r")
  if not h2 then tD._close(); return nil, nil, "Reopen failed" end
  local tPD, sE2 = AX.wrapDevice(h2, fs, p.startSector, p.sizeInSectors)
  if not tPD then fs.close(h2); tD._close(); return nil, nil, sE2 end
  tPD._handle = h2
  tPD._close = function() fs.close(h2); tD._close() end
  return tPD, p
end

local function fmtSz(n)
  if n >= 1048576 then return string.format("%.1f MB", n/1048576) end
  if n >= 1024 then return string.format("%.1f KB", n/1024) end
  return n .. " B"
end

-- =============================================
-- COMMANDS
-- =============================================

local cmd = args[1]

if not cmd or cmd == "help" or cmd == "-h" then
  print(C.C .. "axfs" .. C.R .. " — AxisOS Filesystem Tool")
  print("  axfs scan                         List block devices")
  print("  axfs init <dev>                   Initialize RDB")
  print("  axfs parts <dev>                  Show partitions")
  print("  axfs addpart <dev> <name> <sects> Add partition")
  print("  axfs format <dev> <#> [label]     Format AXFS")
  print("  axfs info <dev> <#>               Filesystem info")
  print("  axfs ls <dev> <#> [path]          List directory")
  print("  axfs cat <dev> <#> <path>         Read file")
  print("  axfs write <dev> <#> <path> <str> Write file")
  print("  axfs mkdir <dev> <#> <path>       Create directory")
  print("  axfs rm <dev> <#> <path>          Remove file/dir")
  print("  axfs stat <dev> <#> <path>        Inode info")
  print("  axfs import <dev> <#> <src> <dst> Copy in from VFS")
  print("  axfs export <dev> <#> <src> <dst> Copy out to VFS")
  return

elseif cmd == "scan" then
  local tDev = fs.list("/dev")
  if not tDev then die("Cannot list /dev"); return end
  local n = 0
  for _, sName in ipairs(tDev) do
    local sC = sName:gsub("/$", "")
    if sC:find("drive", 1, true) then
      local h = fs.open("/dev/" .. sC, "r")
      if h then
        local bI, tI = fs.deviceControl(h, "info", {})
        fs.close(h)
        if bI and tI then
          n = n + 1
          print(string.format("  %s/dev/%-20s%s %s  %d sectors  %d-byte",
            C.Y, sC, C.R, fmtSz(tI.capacity), tI.sectorCount, tI.sectorSize))
        end
      end
    end
  end
  if n == 0 then print(C.D .. "  No block devices found. Install an unmanaged drive and: insmod blkdev" .. C.R) end

elseif cmd == "init" then
  local sDev = args[2]; if not sDev then die("Usage: axfs init <device>"); return end
  local tD, sE = openDev(sDev)
  if not tD then die(sE); return end
  local tRdb = RDB.create("AxisDisk", tD.sectorSize, tD.sectorCount)
  RDB.write(tD, tRdb)
  tD._close()
  ok("RDB initialized on " .. sDev .. " (" .. tD.sectorCount .. " sectors)")

elseif cmd == "parts" then
  local sDev = args[2]; if not sDev then die("Usage: axfs parts <device>"); return end
  local tD, sE = openDev(sDev)
  if not tD then die(sE); return end
  local tRdb, sRE = RDB.read(tD)
  tD._close()
  if not tRdb then die(sRE); return end
  print(C.C .. "Disk: " .. C.R .. tRdb.label .. "  " .. fmtSz(tRdb.totalSectors * tRdb.sectorSize))
  if #tRdb.partitions == 0 then
    print(C.D .. "  No partitions. Use: axfs addpart" .. C.R); return
  end
  print(string.format("  %s%-3s %-12s %-6s %8s %8s %s%s",
    C.D, "#", "NAME", "TYPE", "START", "SIZE", "FLAGS", C.R))
  for i, p in ipairs(tRdb.partitions) do
    print(string.format("  %-3d %s%-12s%s %-6s %8d %8s %s",
      i-1, C.Y, p.name, C.R, p.fsType, p.startSector,
      fmtSz(p.sizeInSectors * tRdb.sectorSize),
      (p.flags % 2 == 1) and "boot" or ""))
  end

elseif cmd == "addpart" then
  local sDev, sName, sSects = args[2], args[3], args[4]
  if not sDev or not sName or not sSects then
    die("Usage: axfs addpart <dev> <name> <sectors>"); return
  end
  local nSects = tonumber(sSects); if not nSects then die("Bad sector count"); return end
  local tD, sE = openDev(sDev); if not tD then die(sE); return end
  local tRdb, sRE = RDB.read(tD)
  if not tRdb then tD._close(); die(sRE); return end
  if #tRdb.partitions >= RDB.MAX_PARTS then tD._close(); die("Max partitions reached"); return end
  local nStart = RDB.nextFree(tRdb)
  if nStart + nSects > tRdb.totalSectors then
    tD._close(); die("Not enough space (max " .. (tRdb.totalSectors - nStart) .. " sectors free)"); return
  end
  table.insert(tRdb.partitions, {name=sName, fsType="axfs", startSector=nStart, sizeInSectors=nSects, flags=0, bootPriority=0})
  RDB.write(tD, tRdb)
  tD._close()
  ok(string.format("Partition '%s' created: sectors %d-%d (%s)",
    sName, nStart, nStart+nSects-1, fmtSz(nSects * tRdb.sectorSize)))

elseif cmd == "rmpart" then
  local sDev, sIdx = args[2], args[3]
  if not sDev or not sIdx then die("Usage: axfs rmpart <dev> <index>"); return end
  local nIdx = tonumber(sIdx); if not nIdx then die("Bad index"); return end
  local tD, sE = openDev(sDev); if not tD then die(sE); return end
  local tRdb, sRE = RDB.read(tD)
  if not tRdb then tD._close(); die(sRE); return end
  if not tRdb.partitions[nIdx+1] then tD._close(); die("No such partition"); return end
  table.remove(tRdb.partitions, nIdx+1)
  RDB.write(tD, tRdb); tD._close()
  ok("Partition " .. nIdx .. " removed")

elseif cmd == "format" then
  local sDev, sPart, sLabel = args[2], args[3], args[4]
  if not sDev or not sPart then die("Usage: axfs format <dev> <part#> [label]"); return end
  local tPD, tPart, sE = openPart(sDev, sPart)
  if not tPD then die(sE); return end
  local bOk, sFE = AX.format(tPD, sLabel or tPart.name)
  tPD._close()
  if bOk then ok("Formatted partition " .. sPart .. " (" .. fmtSz(tPD.sectorCount * tPD.sectorSize) .. ")")
  else die(sFE) end

elseif cmd == "info" then
  local sDev, sPart = args[2], args[3]
  if not sDev or not sPart then die("Usage: axfs info <dev> <part#>"); return end
  local tPD, _, sE = openPart(sDev, sPart)
  if not tPD then die(sE); return end
  local vol, sVE = AX.mount(tPD)
  if not vol then tPD._close(); die(sVE); return end
  local t = vol:info(); vol:unmount(); tPD._close()
  print(C.C .. "AXFS Volume: " .. C.R .. t.label)
  print("  Sector size:   " .. t.sectorSize)
  print("  Total sectors: " .. t.totalSectors)
  print("  Max inodes:    " .. t.maxInodes .. " (free: " .. t.freeInodes .. ")")
  print("  Data blocks:   " .. t.maxBlocks .. " (free: " .. t.freeBlocks .. ")")
  print("  Used:          " .. fmtSz(t.usedKB*1024) .. " / " .. fmtSz(t.totalKB*1024))

elseif cmd == "ls" then
  local sDev, sPart, sPath = args[2], args[3], args[4] or "/"
  if not sDev or not sPart then die("Usage: axfs ls <dev> <part#> [path]"); return end
  local tPD, _, sE = openPart(sDev, sPart); if not tPD then die(sE); return end
  local vol, sVE = AX.mount(tPD); if not vol then tPD._close(); die(sVE); return end
  local ents, sLE = vol:listDir(sPath); vol:unmount(); tPD._close()
  if not ents then die(sLE); return end
  for _, e in ipairs(ents) do
    local sT = ({[1]="f",[2]="d",[3]="l"})[e.iType] or "?"
    local sC = e.iType == 2 and C.C or C.R
    print(string.format("  %s %5d  i%-3d  %s%s%s",
      sT, e.size, e.inode, sC, e.name, C.R))
  end
  if #ents == 0 then print(C.D .. "  (empty)" .. C.R) end

elseif cmd == "cat" then
  local sDev, sPart, sPath = args[2], args[3], args[4]
  if not sDev or not sPart or not sPath then die("Usage: axfs cat <dev> <part#> <path>"); return end
  local tPD, _, sE = openPart(sDev, sPart); if not tPD then die(sE); return end
  local vol, sVE = AX.mount(tPD); if not vol then tPD._close(); die(sVE); return end
  local data, sFE = vol:readFile(sPath); vol:unmount(); tPD._close()
  if data then io.write(data) else die(sFE) end

elseif cmd == "write" then
  local sDev, sPart, sPath, sData = args[2], args[3], args[4], args[5]
  if not sDev or not sPart or not sPath or not sData then
    die("Usage: axfs write <dev> <part#> <path> <data>"); return
  end
  local tPD, _, sE = openPart(sDev, sPart); if not tPD then die(sE); return end
  local vol, sVE = AX.mount(tPD); if not vol then tPD._close(); die(sVE); return end
  local bOk, sFE = vol:writeFile(sPath, sData); vol:unmount(); tPD._close()
  if bOk then ok("Written " .. #sData .. "B to " .. sPath) else die(sFE) end

elseif cmd == "mkdir" then
  local sDev, sPart, sPath = args[2], args[3], args[4]
  if not sDev or not sPart or not sPath then die("Usage: axfs mkdir <dev> <part#> <path>"); return end
  local tPD, _, sE = openPart(sDev, sPart); if not tPD then die(sE); return end
  local vol, sVE = AX.mount(tPD); if not vol then tPD._close(); die(sVE); return end
  local bOk, sFE = vol:mkdir(sPath); vol:unmount(); tPD._close()
  if bOk then ok("Created " .. sPath) else die(sFE) end

elseif cmd == "rm" then
  local sDev, sPart, sPath = args[2], args[3], args[4]
  if not sDev or not sPart or not sPath then die("Usage: axfs rm <dev> <part#> <path>"); return end
  local tPD, _, sE = openPart(sDev, sPart); if not tPD then die(sE); return end
  local vol, sVE = AX.mount(tPD); if not vol then tPD._close(); die(sVE); return end
  local bOk, sFE = vol:removeFile(sPath)
  if not bOk then bOk, sFE = vol:rmdir(sPath) end
  vol:unmount(); tPD._close()
  if bOk then ok("Removed " .. sPath) else die(sFE) end

elseif cmd == "stat" then
  local sDev, sPart, sPath = args[2], args[3], args[4]
  if not sDev or not sPart or not sPath then die("Usage: axfs stat <dev> <part#> <path>"); return end
  local tPD, _, sE = openPart(sDev, sPart); if not tPD then die(sE); return end
  local vol, sVE = AX.mount(tPD); if not vol then tPD._close(); die(sVE); return end
  local t, sFE = vol:stat(sPath); vol:unmount(); tPD._close()
  if not t then die(sFE); return end
  local tN = {[0]="free",[1]="file",[2]="dir",[3]="symlink"}
  print(C.C .. "Inode " .. t.inode .. C.R)
  print("  Type:     " .. (tN[t.iType] or "?"))
  print("  Mode:     " .. string.format("%03o", t.mode))
  print("  Size:     " .. t.size .. " bytes")
  print("  Links:    " .. t.links)
  print("  Blocks:   " .. t.nBlk)
  print("  UID/GID:  " .. t.uid .. "/" .. t.gid)
  print("  Created:  " .. t.ctime)
  print("  Modified: " .. t.mtime)

elseif cmd == "import" then
  local sDev, sPart, sSrc, sDst = args[2], args[3], args[4], args[5]
  if not sDev or not sPart or not sSrc or not sDst then
    die("Usage: axfs import <dev> <part#> <vfs_src> <axfs_dst>"); return
  end
  -- Read from managed FS
  local hSrc = fs.open(sSrc, "r")
  if not hSrc then die("Cannot open " .. sSrc); return end
  local tChunks = {}
  while true do
    local s = fs.read(hSrc, math.huge); if not s then break end
    tChunks[#tChunks+1] = s
  end
  fs.close(hSrc)
  local sData = table.concat(tChunks)
  -- Write to AXFS
  local tPD, _, sE = openPart(sDev, sPart); if not tPD then die(sE); return end
  local vol, sVE = AX.mount(tPD); if not vol then tPD._close(); die(sVE); return end
  local bOk, sFE = vol:writeFile(sDst, sData); vol:unmount(); tPD._close()
  if bOk then ok("Imported " .. fmtSz(#sData) .. " from " .. sSrc .. " → " .. sDst)
  else die(sFE) end

elseif cmd == "export" then
  local sDev, sPart, sSrc, sDst = args[2], args[3], args[4], args[5]
  if not sDev or not sPart or not sSrc or not sDst then
    die("Usage: axfs export <dev> <part#> <axfs_src> <vfs_dst>"); return
  end
  local tPD, _, sE = openPart(sDev, sPart); if not tPD then die(sE); return end
  local vol, sVE = AX.mount(tPD); if not vol then tPD._close(); die(sVE); return end
  local sData, sFE = vol:readFile(sSrc); vol:unmount(); tPD._close()
  if not sData then die(sFE); return end
  local hDst = fs.open(sDst, "w")
  if not hDst then die("Cannot write " .. sDst); return end
  fs.write(hDst, sData); fs.close(hDst)
  ok("Exported " .. fmtSz(#sData) .. " from " .. sSrc .. " → " .. sDst)

else
  die("Unknown command: " .. cmd .. "  (try: axfs help)")
end