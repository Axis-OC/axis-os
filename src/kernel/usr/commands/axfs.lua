--
-- /usr/commands/axfs.lua
-- AXFS v2 multi-tool: partition, format, mount, read/write, install, flash
--
-- Usage:
--   axfs scan                              List block devices
--   axfs init <dev>                        Write empty RDB
--   axfs parts <dev>                       Show partitions
--   axfs addpart <dev> <name> [sectors]    Create partition (0/omit = all free)
--   axfs rmpart <dev> <index>              Remove partition
--   axfs format <dev> <part> [label]       Format with AXFS v2
--   axfs info <dev> <part>                 FS info
--   axfs ls <dev> <part> [path]            List directory
--   axfs cat <dev> <part> <path>           Read file
--   axfs write <dev> <part> <path> <data>  Write file
--   axfs mkdir <dev> <part> <path>         Create directory
--   axfs rm <dev> <part> <path>            Remove file/dir
--   axfs stat <dev> <part> <path>          Inode info
--   axfs import <dev> <part> <src> <dst>   Managed FS -> AXFS
--   axfs export <dev> <part> <src> <dst>   AXFS -> Managed FS
--   axfs install <dev> <part>              Copy full OS tree to AXFS
--   axfs flash [boot_file]                 Flash EEPROM (Ring 0-2 only)
--
-- <part> can be a numeric index (0,1,2..) or a partition name (DH0, SYSTEM..)
--

local fs = require("filesystem")
local AX = require("axfs_core")
local RDB = require("rdb")
local B = require("bpack")
local args = env.ARGS or {}

local C = {R="\27[37m",G="\27[32m",Y="\27[33m",C="\27[36m",E="\27[31m",D="\27[90m"}

local function die(s) print(C.E .. "Error: " .. C.R .. s) end
local function ok(s)  print(C.G .. "[OK] " .. C.R .. s) end

local function fmtSz(n)
  if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
  if n >= 1024 then return string.format("%.1f KB", n / 1024) end
  return n .. " B"
end

-- =============================================
-- DEVICE HELPERS
-- =============================================

-- Open a block device in /dev, return a tDisk wrapper.
-- Sector numbering is 0-based internally; the +1 for OC's
-- 1-based readSector/writeSector is handled here.
local function openDev(sPath)
  local h = fs.open(sPath, "r")
  if not h then return nil, "Cannot open " .. sPath end
  local bI, tI = fs.deviceControl(h, "info", {})
  if not bI or not tI then
    fs.close(h); return nil, "Device info failed (is blkdev driver loaded?)"
  end
  local ss = tI.sectorSize
  local sc = tI.sectorCount
  return {
    sectorSize  = ss,
    sectorCount = sc,
    readSector = function(n)
      local bOk, sData = fs.deviceControl(h, "read_sector", {n + 1})
      return bOk and sData or nil
    end,
    writeSector = function(n, sData)
      sData = sData or ""
      local sPad = B.pad(sData, ss)
      return fs.deviceControl(h, "write_sector", {n + 1, sPad:sub(1, ss)})
    end,
    close = function() fs.close(h) end,
  }
end

-- Resolve a partition specifier: numeric index OR device name / label.
-- Returns 0-based index or nil.
local function resolvePart(tRdb, sPart)
  local nIdx = tonumber(sPart)
  if nIdx then
    if tRdb.partitions[nIdx + 1] then return nIdx end
    return nil
  end
  -- Name / label lookup
  for i, p in ipairs(tRdb.partitions) do
    if p.deviceName == sPart or p.fsLabel == sPart then
      return i - 1
    end
  end
  return nil
end

-- Open device + partition -> partition-scoped tDisk
local function openPart(sPath, sPart)
  local tD, sErr = openDev(sPath)
  if not tD then return nil, nil, sErr end

  local tRdb, sRE = RDB.read(tD)
  if not tRdb then tD.close(); return nil, nil, sRE end

  local nIdx = resolvePart(tRdb, sPart)
  if not nIdx then
    tD.close()
    -- Build helpful error
    local sAvail = ""
    if #tRdb.partitions > 0 then
      local tNames = {}
      for i, p in ipairs(tRdb.partitions) do
        tNames[#tNames+1] = string.format("%d (%s)", i-1, p.deviceName or "?")
      end
      sAvail = "\n  Available: " .. table.concat(tNames, ", ")
    else
      sAvail = "\n  (no partitions — use: axfs addpart)"
    end
    return nil, nil, "Partition '" .. tostring(sPart) .. "' not found" .. sAvail
  end

  local p   = tRdb.partitions[nIdx + 1]
  local nOff = p.startSector
  local nCnt = p.sizeSectors
  local ss   = tD.sectorSize

  local tPD = {
    sectorSize  = ss,
    sectorCount = nCnt,
    readSector  = function(n) return tD.readSector(nOff + n) end,
    writeSector = function(n, sData) return tD.writeSector(nOff + n, sData) end,
    close       = function() tD.close() end,
  }
  return tPD, p
end

-- =============================================
-- COMMAND DISPATCH
-- =============================================

local cmd = args[1]

-- =============================================
-- HELP
-- =============================================
if not cmd or cmd == "help" or cmd == "-h" then
  print(C.C .. "axfs" .. C.R .. " — AxisOS Filesystem Tool")
  print("")
  print("  " .. C.Y .. "Disk / Partition:" .. C.R)
  print("    axfs scan                          List block devices")
  print("    axfs init <dev>                    Initialize RDB on device")
  print("    axfs parts <dev>                   Show partition table")
  print("    axfs addpart <dev> <name> [sects]  Add partition (omit = all free)")
  print("    axfs rmpart <dev> <index>          Remove partition by index")
  print("")
  print("  " .. C.Y .. "Filesystem:" .. C.R)
  print("    axfs format <dev> <part> [label]   Format partition as AXFS v2")
  print("    axfs info <dev> <part>             Show volume info")
  print("")
  print("  " .. C.Y .. "File Operations:" .. C.R)
  print("    axfs ls <dev> <part> [path]        List directory")
  print("    axfs cat <dev> <part> <path>       Read file")
  print("    axfs write <dev> <part> <path> <d> Write string to file")
  print("    axfs mkdir <dev> <part> <path>     Create directory")
  print("    axfs rm <dev> <part> <path>        Remove file or directory")
  print("    axfs stat <dev> <part> <path>      Show inode details")
  print("    axfs import <dev> <part> <s> <d>   Copy VFS file into AXFS")
  print("    axfs export <dev> <part> <s> <d>   Copy AXFS file to VFS")
  print("")
  print("  " .. C.Y .. "Deployment:" .. C.R)
  print("    axfs install <dev> <part>          Copy entire OS tree to AXFS")
  print("    axfs flash [file]                  Flash EEPROM bootloader (Ring 0-2)")
  print("")
  print("  <part> = numeric index (0,1..) or name (DH0, SYSTEM..)")
  return

-- =============================================
-- SCAN
-- =============================================
elseif cmd == "scan" then
  local tDev = fs.list("/dev")
  if not tDev then die("Cannot list /dev"); return end
  local n = 0
  for _, sName in ipairs(tDev) do
    local sClean = sName:gsub("/$", "")
    if sClean:find("drive", 1, true) then
      local hDev = fs.open("/dev/" .. sClean, "r")
      if hDev then
        local bI, tI = fs.deviceControl(hDev, "info", {})
        fs.close(hDev)
        if bI and tI then
          n = n + 1
          local nCap = tI.capacity or (tI.sectorCount * tI.sectorSize)
          print(string.format("  %s/dev/%-22s%s %7s  %d sectors × %dB",
            C.Y, sClean, C.R, fmtSz(nCap), tI.sectorCount, tI.sectorSize))
        end
      end
    end
  end
  if n == 0 then
    print(C.E .. "  No block devices found." .. C.R)
    print("")
    print("  Load the driver:  " .. C.Y .. "insmod blkdev" .. C.R)
    print("  Auto-load at boot: " .. C.Y .. "drvconf enable blkdev" .. C.R)
  end

-- =============================================
-- INIT — write empty RDB
-- =============================================
elseif cmd == "init" then
  local sDev = args[2]
  if not sDev then die("Usage: axfs init <device>"); return end
  local tD, sE = openDev(sDev)
  if not tD then die(sE); return end

  -- Warn if RDB already present
  local sFirst = tD.readSector(0)
  if sFirst and #sFirst >= 4 and sFirst:sub(1, 4) == "RDSK" then
    print(C.Y .. "  Device already has an RDB. This will erase the partition table." .. C.R)
    io.write(C.Y .. "  Continue? (y/N): " .. C.R)
    local sConf = io.read()
    if not sConf or (sConf:lower() ~= "y" and sConf:lower() ~= "yes") then
      tD.close(); print("  Aborted."); return
    end
  end

  local nSC = tD.sectorCount
  local ss  = tD.sectorSize
  local tRdb = {
    label        = "AxisDisk",
    totalSectors = nSC,
    generation   = 0,
    partitions   = {},
  }
  RDB.write(tD, tRdb)
  tD.close()

  local nFree = nSC - (RDB.MAX_PARTS + 1)
  ok("RDB initialized on " .. sDev)
  print(C.D .. "  " .. nSC .. " sectors (" .. fmtSz(nSC * ss) ..
        "), " .. nFree .. " sectors free for partitions" .. C.R)

-- =============================================
-- PARTS — show partition table
-- =============================================
elseif cmd == "parts" then
  local sDev = args[2]
  if not sDev then die("Usage: axfs parts <device>"); return end
  local tD, sE = openDev(sDev)
  if not tD then die(sE); return end
  local tRdb, sRE = RDB.read(tD)
  local ss = tD.sectorSize
  tD.close()
  if not tRdb then die(sRE); return end

  local nDiskSz = tRdb.totalSectors * (tRdb.sectorSize or ss)
  print(C.C .. "Disk: " .. C.R .. (tRdb.label or "?") .. "  " .. fmtSz(nDiskSz) ..
        "  gen=" .. (tRdb.generation or 0))

  if #tRdb.partitions == 0 then
    print(C.D .. "  No partitions." .. C.R)
    print("  Create one: axfs addpart " .. sDev .. " SYSTEM")
    return
  end

  print(string.format("  %s%-3s %-8s %-8s %-10s %8s %10s %s%s",
    C.D, "#", "DEVICE", "LABEL", "FSTYPE", "START", "SIZE", "FLAGS", C.R))

  for i, p in ipairs(tRdb.partitions) do
    local tFlags = {}
    if bit32.band(p.flags or 0, RDB.PF_BOOTABLE)  ~= 0 then tFlags[#tFlags+1] = "boot" end
    if bit32.band(p.flags or 0, RDB.PF_AUTOMOUNT)  ~= 0 then tFlags[#tFlags+1] = "auto" end
    if bit32.band(p.flags or 0, RDB.PF_READONLY)   ~= 0 then tFlags[#tFlags+1] = "ro" end

    print(string.format("  %-3d %s%-8s%s %-8s %-10s %8d %10s %s",
      i - 1,
      C.Y, p.deviceName or "?", C.R,
      p.fsLabel or "",
      RDB.fsTypeName(p.fsType),
      p.startSector,
      fmtSz(p.sizeSectors * (tRdb.sectorSize or ss)),
      table.concat(tFlags, ",")))
  end

  local nFree = tRdb.totalSectors - RDB.nextFree(tRdb)
  if nFree > 0 then
    print(C.D .. "  Free: " .. nFree .. " sectors (" .. fmtSz(nFree * (tRdb.sectorSize or ss)) .. ")" .. C.R)
  end

-- =============================================
-- ADDPART — create a partition
-- =============================================
elseif cmd == "addpart" then
  local sDev  = args[2]
  local sName = args[3]
  local sSects = args[4]  -- optional; nil or "0" = all free

  if not sDev or not sName then
    die("Usage: axfs addpart <dev> <name> [sectors]")
    print("  Omit sectors or pass 0 to use all remaining space.")
    return
  end

  local tD, sE = openDev(sDev)
  if not tD then die(sE); return end
  local tRdb, sRE = RDB.read(tD)
  if not tRdb then tD.close(); die(sRE); return end

  if #tRdb.partitions >= RDB.MAX_PARTS then
    tD.close(); die("Maximum " .. RDB.MAX_PARTS .. " partitions reached"); return
  end

  local nStart   = RDB.nextFree(tRdb)
  local nMaxFree = tRdb.totalSectors - nStart
  local nSects   = tonumber(sSects) or 0

  -- 0 or omitted = use all free space
  if nSects <= 0 then nSects = nMaxFree end

  if nMaxFree <= 0 then
    tD.close()
    die("No free space on device (all " .. tRdb.totalSectors .. " sectors allocated)")
    return
  end

  if nSects > nMaxFree then
    tD.close()
    die("Requested " .. nSects .. " sectors, only " .. nMaxFree .. " available")
    return
  end

  local ss = tD.sectorSize

  table.insert(tRdb.partitions, {
    deviceName   = sName,
    fsLabel      = sName,
    startSector  = nStart,
    sizeSectors  = nSects,
    fsType       = RDB.FS_AXFS2,
    flags        = RDB.PF_AUTOMOUNT,
    bootPriority = 0,
    reserved     = 0,
  })

  RDB.write(tD, tRdb)
  tD.close()

  ok(string.format("Partition '%s' (#%d): sectors %d–%d (%s)",
    sName, #tRdb.partitions - 1,
    nStart, nStart + nSects - 1,
    fmtSz(nSects * ss)))

-- =============================================
-- RMPART — remove a partition
-- =============================================
elseif cmd == "rmpart" then
  local sDev = args[2]
  local sIdx = args[3]
  if not sDev or not sIdx then die("Usage: axfs rmpart <dev> <index>"); return end
  local nIdx = tonumber(sIdx)
  if not nIdx then die("Partition index must be a number"); return end

  local tD, sE = openDev(sDev)
  if not tD then die(sE); return end
  local tRdb, sRE = RDB.read(tD)
  if not tRdb then tD.close(); die(sRE); return end

  if not tRdb.partitions[nIdx + 1] then
    tD.close(); die("No partition at index " .. nIdx); return
  end

  local sRemoved = tRdb.partitions[nIdx + 1].deviceName or "?"
  table.remove(tRdb.partitions, nIdx + 1)
  RDB.write(tD, tRdb)
  tD.close()
  ok("Removed partition " .. nIdx .. " (" .. sRemoved .. ")")

-- =============================================
-- FORMAT — format partition as AXFS v2
-- =============================================
elseif cmd == "format" then
  local sDev   = args[2]
  local sPart  = args[3]
  local sLabel = args[4]

  if not sDev or not sPart then
    die("Usage: axfs format <dev> <part> [label]"); return
  end

  local tPD, tPart, sE = openPart(sDev, sPart)
  if not tPD then die(sE); return end

  local sVolLabel = sLabel or tPart.fsLabel or tPart.deviceName or "AxisFS"
  local bOk, sFE = AX.format(tPD, sVolLabel)
  local nSz = tPD.sectorCount * tPD.sectorSize
  tPD.close()

  if bOk then
    ok("Formatted '" .. sVolLabel .. "' (" .. fmtSz(nSz) .. ")")
  else
    die("Format failed: " .. tostring(sFE))
  end

-- =============================================
-- INFO — AXFS volume info
-- =============================================
elseif cmd == "info" then
  local sDev  = args[2]
  local sPart = args[3]
  if not sDev or not sPart then die("Usage: axfs info <dev> <part>"); return end

  local tPD, _, sE = openPart(sDev, sPart)
  if not tPD then die(sE); return end

  local vol, sVE = AX.mount(tPD)
  if not vol then tPD.close(); die(sVE); return end

  local t = vol:info()
  vol:unmount(); tPD.close()

  print(C.C .. "AXFS Volume: " .. C.R .. t.label)
  print("  Version:       " .. (t.version or "?"))
  print("  Sector size:   " .. t.sectorSize)
  print("  Total sectors: " .. t.totalSectors)
  print("  Max inodes:    " .. t.maxInodes .. " (free: " .. t.freeInodes .. ")")
  print("  Data blocks:   " .. t.maxBlocks .. " (free: " .. t.freeBlocks .. ")")
  print("  Used:          " .. fmtSz(t.usedKB * 1024) .. " / " .. fmtSz(t.totalKB * 1024))
  print("  Generation:    " .. (t.generation or 0))
  if t.inlineSupport then
    print("  Inline data:   " .. C.G .. "yes (files ≤52B stored in inode)" .. C.R)
  end

-- =============================================
-- LS — list directory
-- =============================================
elseif cmd == "ls" then
  local sDev, sPart, sPath = args[2], args[3], args[4] or "/"
  if not sDev or not sPart then die("Usage: axfs ls <dev> <part> [path]"); return end

  local tPD, _, sE = openPart(sDev, sPart)
  if not tPD then die(sE); return end
  local vol, sVE = AX.mount(tPD)
  if not vol then tPD.close(); die(sVE); return end

  local ents, sLE = vol:listDir(sPath)
  vol:unmount(); tPD.close()
  if not ents then die(sLE); return end

  for _, e in ipairs(ents) do
    local sT   = ({[1]="f",[2]="d",[3]="l"})[e.iType] or "?"
    local sClr = e.iType == 2 and C.C or C.R
    local sTag = e.inline and (C.D .. " [inline]" .. C.R) or ""
    print(string.format("  %s %6d  i%-4d %s%s%s%s",
      sT, e.size, e.inode, sClr, e.name, C.R, sTag))
  end
  if #ents == 0 then print(C.D .. "  (empty)" .. C.R) end

-- =============================================
-- CAT — read file
-- =============================================
elseif cmd == "cat" then
  local sDev, sPart, sPath = args[2], args[3], args[4]
  if not sDev or not sPart or not sPath then
    die("Usage: axfs cat <dev> <part> <path>"); return
  end
  local tPD, _, sE = openPart(sDev, sPart)
  if not tPD then die(sE); return end
  local vol, sVE = AX.mount(tPD)
  if not vol then tPD.close(); die(sVE); return end
  local data, sFE = vol:readFile(sPath)
  vol:unmount(); tPD.close()
  if data then io.write(data) else die(sFE) end

-- =============================================
-- WRITE — write string to file
-- =============================================
elseif cmd == "write" then
  local sDev, sPart, sPath, sData = args[2], args[3], args[4], args[5]
  if not sDev or not sPart or not sPath or not sData then
    die("Usage: axfs write <dev> <part> <path> <data>"); return
  end
  local tPD, _, sE = openPart(sDev, sPart)
  if not tPD then die(sE); return end
  local vol, sVE = AX.mount(tPD)
  if not vol then tPD.close(); die(sVE); return end
  local bOk, sFE = vol:writeFile(sPath, sData)
  vol:unmount(); tPD.close()
  if bOk then ok("Written " .. #sData .. "B to " .. sPath) else die(sFE) end

-- =============================================
-- MKDIR
-- =============================================
elseif cmd == "mkdir" then
  local sDev, sPart, sPath = args[2], args[3], args[4]
  if not sDev or not sPart or not sPath then
    die("Usage: axfs mkdir <dev> <part> <path>"); return
  end
  local tPD, _, sE = openPart(sDev, sPart)
  if not tPD then die(sE); return end
  local vol, sVE = AX.mount(tPD)
  if not vol then tPD.close(); die(sVE); return end
  local bOk, sFE = vol:mkdir(sPath)
  vol:unmount(); tPD.close()
  if bOk then ok("Created " .. sPath) else die(sFE) end

-- =============================================
-- RM — remove file or directory
-- =============================================
elseif cmd == "rm" then
  local sDev, sPart, sPath = args[2], args[3], args[4]
  if not sDev or not sPart or not sPath then
    die("Usage: axfs rm <dev> <part> <path>"); return
  end
  local tPD, _, sE = openPart(sDev, sPart)
  if not tPD then die(sE); return end
  local vol, sVE = AX.mount(tPD)
  if not vol then tPD.close(); die(sVE); return end
  local bOk, sFE = vol:removeFile(sPath)
  if not bOk then bOk, sFE = vol:rmdir(sPath) end
  vol:unmount(); tPD.close()
  if bOk then ok("Removed " .. sPath) else die(sFE) end

-- =============================================
-- STAT — inode info
-- =============================================
elseif cmd == "stat" then
  local sDev, sPart, sPath = args[2], args[3], args[4]
  if not sDev or not sPart or not sPath then
    die("Usage: axfs stat <dev> <part> <path>"); return
  end
  local tPD, _, sE = openPart(sDev, sPart)
  if not tPD then die(sE); return end
  local vol, sVE = AX.mount(tPD)
  if not vol then tPD.close(); die(sVE); return end
  local t, sFE = vol:stat(sPath)
  vol:unmount(); tPD.close()
  if not t then die(sFE); return end
  local tN = {[0]="free",[1]="file",[2]="dir",[3]="symlink"}
  print(C.C .. "Inode " .. t.inode .. C.R)
  print("  Type:     " .. (tN[t.iType] or "?"))
  print("  Mode:     " .. string.format("%03o", t.mode))
  print("  Size:     " .. t.size .. " bytes")
  print("  Links:    " .. t.links)
  print("  Extents:  " .. (t.nExtents or 0))
  print("  Inline:   " .. tostring(t.isInline or false))
  print("  Flags:    " .. string.format("0x%02X", t.flags or 0))
  print("  UID/GID:  " .. t.uid .. "/" .. t.gid)
  print("  Created:  " .. t.ctime)
  print("  Modified: " .. t.mtime)

-- =============================================
-- IMPORT — copy VFS file into AXFS
-- =============================================
elseif cmd == "import" then
  local sDev, sPart, sSrc, sDst = args[2], args[3], args[4], args[5]
  if not sDev or not sPart or not sSrc or not sDst then
    die("Usage: axfs import <dev> <part> <vfs_src> <axfs_dst>"); return
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
  local tPD, _, sE = openPart(sDev, sPart)
  if not tPD then die(sE); return end
  local vol, sVE = AX.mount(tPD)
  if not vol then tPD.close(); die(sVE); return end
  local bOk, sFE = vol:writeFile(sDst, sData)
  vol:unmount(); tPD.close()
  if bOk then ok("Imported " .. fmtSz(#sData) .. " from " .. sSrc .. " → " .. sDst)
  else die(sFE) end

-- =============================================
-- EXPORT — copy AXFS file to VFS
-- =============================================
elseif cmd == "export" then
  local sDev, sPart, sSrc, sDst = args[2], args[3], args[4], args[5]
  if not sDev or not sPart or not sSrc or not sDst then
    die("Usage: axfs export <dev> <part> <axfs_src> <vfs_dst>"); return
  end
  local tPD, _, sE = openPart(sDev, sPart)
  if not tPD then die(sE); return end
  local vol, sVE = AX.mount(tPD)
  if not vol then tPD.close(); die(sVE); return end
  local sData, sFE = vol:readFile(sSrc)
  vol:unmount(); tPD.close()
  if not sData then die(sFE); return end
  local hDst = fs.open(sDst, "w")
  if not hDst then die("Cannot write " .. sDst); return end
  fs.write(hDst, sData); fs.close(hDst)
  ok("Exported " .. fmtSz(#sData) .. " from " .. sSrc .. " → " .. sDst)

-- =============================================
-- INSTALL — copy entire OS tree to AXFS partition
-- =============================================
elseif cmd == "install" then
  local sDev  = args[2]
  local sPart = args[3]
  if not sDev or not sPart then
    die("Usage: axfs install <dev> <part>")
    print("  Copies the running OS filesystem onto an AXFS partition.")
    print("  After install, flash the AXFS bootloader: axfs flash")
    return
  end

  local tPD, tPart, sE = openPart(sDev, sPart)
  if not tPD then die(sE); return end
  local vol, sVE = AX.mount(tPD)
  if not vol then tPD.close(); die(sVE); return end

  local tSkip = {
    ["/tmp"]=true, ["/log"]=true, ["/vbl"]=true, ["/dev"]=true,
  }

  local nFiles, nDirs, nBytes, nErrors = 0, 0, 0, 0
  local tCreatedDirs = {}

  local function ensureParents(sPath)
    local tParts = {}
    for seg in sPath:gmatch("[^/]+") do tParts[#tParts+1] = seg end
    if #tParts <= 1 then return end
    table.remove(tParts)
    local sDir = ""
    for _, seg in ipairs(tParts) do
      sDir = sDir .. "/" .. seg
      if not tCreatedDirs[sDir] then
        vol:mkdir(sDir)
        tCreatedDirs[sDir] = true
        syscall("process_yield")
      end
    end
  end

  local function copyTree(sSrcDir, sDstDir)
    syscall("process_yield")
    local tList = fs.list(sSrcDir)
    if not tList then return end
    for _, sName in ipairs(tList) do
      local bIsDir = sName:sub(-1) == "/"
      local sClean = bIsDir and sName:sub(1, -2) or sName
      local sSrc = (sSrcDir == "/" and "" or sSrcDir) .. "/" .. sClean
      local sDst = (sDstDir == "/" and "" or sDstDir) .. "/" .. sClean
      sSrc = sSrc:gsub("//", "/")
      sDst = sDst:gsub("//", "/")

      if tSkip[sSrc] then
        io.write(C.D .. "  SKIP  " .. sSrc .. C.R .. "\n")
      elseif bIsDir then
        vol:mkdir(sDst)
        tCreatedDirs[sDst] = true
        nDirs = nDirs + 1
        io.write(C.Y .. "  DIR   " .. sDst .. C.R .. "\n")
        syscall("process_yield")
        copyTree(sSrc, sDst)
      else
        ensureParents(sDst)

        local hSrc = fs.open(sSrc, "r")
        if hSrc then
          local tC = {}
          while true do
            local s = fs.read(hSrc, math.huge); if not s then break end
            tC[#tC+1] = s
          end
          fs.close(hSrc)

          -- Yield between read and write — the read phase consumed
          -- time and the AXFS write will do heavy uninstrumented work
          syscall("process_yield")

          local sData = table.concat(tC):gsub("\r\n", "\n")
          local bW, sWE = vol:writeFile(sDst, sData)
          if bW then
            nFiles = nFiles + 1
            nBytes = nBytes + #sData
            io.write(C.G .. "  FILE  " .. C.R .. sDst ..
                     C.D .. " (" .. #sData .. "B)" .. C.R .. "\n")
          else
            nErrors = nErrors + 1
            io.write(C.E .. "  FAIL  " .. sDst .. ": " .. tostring(sWE) .. C.R .. "\n")
          end
        else
          nErrors = nErrors + 1
          io.write(C.E .. "  FAIL  Cannot read " .. sSrc .. C.R .. "\n")
        end
      end

      -- Yield after every single entry
      syscall("process_yield")
    end
  end

  print(C.C .. "Installing AxisOS to AXFS partition..." .. C.R)
  print("")

  -- Pre-create essential directories WITH yields between each
  for _, sDir in ipairs({
    "/bin", "/etc", "/lib", "/drivers", "/system",
    "/usr", "/usr/commands", "/home", "/tmp", "/boot",
    "/system/lib", "/system/lib/dk", "/lib/vi", "/lib/hbm",
    "/lib/xevi", "/sys", "/sys/security", "/sys/drivers",
    "/etc/xevi", "/etc/xevi/plug", "/root", "/home/guest",
    "/boot/sys",
  }) do
    vol:mkdir(sDir)
    tCreatedDirs[sDir] = true
    syscall("process_yield")
  end

  -- Flush metadata to disk and yield before the heavy copy phase
  vol:flush()
  syscall("process_yield")

  local bCopyOk, sCopyErr = pcall(copyTree, "/", "/")
  if not bCopyOk then
    print(C.E .. "\n  INSTALL CRASHED: " .. tostring(sCopyErr) .. C.R)
    nErrors = nErrors + 1
  end

  vol:flush()
  tPD.close()

  print("")
  print(C.C .. string.rep("=", 50) .. C.R)
  print(C.G .. "  Install complete!" .. C.R)
  print(string.format("  %d files, %d directories, %s",
    nFiles, nDirs, fmtSz(nBytes)))
  if nErrors > 0 then
    print(C.E .. "  " .. nErrors .. " error(s)" .. C.R)
  end
  print(C.C .. string.rep("=", 50) .. C.R)
  print("")
  print("  Next: " .. C.Y .. "axfs flash" .. C.R .. " to write the AXFS bootloader to EEPROM")

-- =============================================
-- FLASH — write AXFS bootloader to EEPROM
-- =============================================
elseif cmd == "flash" then
  local sBoot = args[2] or "/boot/axfs_boot.lua"

  -- Ring check
  local nRing = syscall("process_get_ring")
  if nRing > 2 then
    die("EEPROM flash requires Ring 0–2")
    print("  Login as " .. C.Y .. "dev" .. C.R .. " (Ring 0) to flash EEPROM,")
    print("  or use BIOS Setup (DEL at boot) → SecureBoot & PKI.")
    return
  end

  -- Find EEPROM
  local bListOk, tEepList = syscall("raw_component_list", "eeprom")
  if not bListOk or not tEepList then die("No EEPROM found"); return end
  local oEep
  for addr in pairs(tEepList) do
    oEep = syscall("raw_component_proxy", addr); break
  end
  if not oEep then die("Cannot access EEPROM"); return end

  -- Read boot code from file
  local hBoot = fs.open(sBoot, "r")
  if not hBoot then
    die("Cannot read " .. sBoot)
    print("")
    print("  Available boot EEPROMs:")
    print("    " .. C.C .. "/boot/axfs_boot.lua" .. C.R .. "        AXFS v2 boot")
    print("    " .. C.C .. "/boot/boot.lua" .. C.R .. "             Managed FS boot (with menu)")
    print("    " .. C.C .. "/boot/boot_secure.lua" .. C.R .. "      SecureBoot (managed FS)")
    return
  end
  local tC = {}
  while true do
    local s = fs.read(hBoot, math.huge); if not s then break end; tC[#tC+1] = s
  end
  fs.close(hBoot)
  local sCode = table.concat(tC)

  if #sCode > 4096 then
    die("Boot code too large: " .. #sCode .. " bytes (max 4096)")
    return
  end

  print(C.C .. "Flash EEPROM" .. C.R)
  print("  Source: " .. sBoot)
  print("  Size:   " .. #sCode .. " / 4096 bytes (" .. (4096 - #sCode) .. " free)")
  print("")
  io.write(C.Y .. "  Type 'FLASH' to confirm: " .. C.R)
  local sConfirm = io.read()
  if sConfirm ~= "FLASH" then print("  Aborted."); return end

  oEep.set(sCode)
  if sBoot:find("axfs") then
    oEep.setLabel("AxisOS AXFS Boot")
  elseif sBoot:find("secure") then
    oEep.setLabel("AxisOS SecureBoot")
  else
    oEep.setLabel("AxisOS Boot")
  end

  print("")
  ok("EEPROM flashed successfully!")
  print("  Reboot to use the new bootloader.")

-- =============================================
-- UNKNOWN COMMAND
-- =============================================
else
  die("Unknown command: " .. tostring(cmd))
  print("  Run " .. C.C .. "axfs help" .. C.R .. " for usage.")
end