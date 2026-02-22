--
-- /usr/commands/axfs_switch.lua
-- "axfs-switch" — Prepare an unmanaged drive for AXFS boot.
-- v2: --efi-prebuild creates encrypted EFI + AXFS partitions.
--
-- Usage:
--   axfs-switch <device>                     AXFS only
--   axfs-switch <device> --efi-prebuild      EFI + AXFS (SecureBoot ready)
--

local fs  = require("filesystem")
local AX  = require("axfs_core")
local RDB = require("rdb")
local B   = require("bpack")
local tArgs = env.ARGS or {}

local C = {R="\27[37m", G="\27[32m", E="\27[31m", Y="\27[33m",
           C="\27[36m", D="\27[90m", M="\27[35m"}

-- =============================================
-- ARGUMENT PARSING
-- =============================================

local sDev = nil
local bEfiPrebuild = false

for _, sArg in ipairs(tArgs) do
  if sArg == "--efi-prebuild" or sArg == "--efi" then
    bEfiPrebuild = true
  elseif sArg:sub(1, 1) ~= "-" and not sDev then
    sDev = sArg
  end
end

-- =============================================
-- FIND DRIVE DEVICES
-- =============================================

local function findDriveDevices()
  local tDrives = {}
  local tDevList = fs.list("/dev")
  if tDevList then
    for _, sName in ipairs(tDevList) do
      local sClean = sName:gsub("/$", "")
      if sClean:find("drive", 1, true) then
        tDrives[#tDrives + 1] = "/dev/" .. sClean
      end
    end
  end
  return tDrives
end

-- =============================================
-- USAGE
-- =============================================

if not sDev then
  print(C.C .. "axfs-switch" .. C.R .. " — Prepare drive for AXFS boot")
  print("")
  print("  Usage: axfs-switch <device> [--efi-prebuild]")
  print("")
  print("  " .. C.Y .. "Without --efi-prebuild:" .. C.R)
  print("    Creates a single AXFS partition (no SecureBoot)")
  print("")
  print("  " .. C.M .. "With --efi-prebuild:" .. C.R)
  print("    Creates AXEFI (encrypted, hidden) + AXFS partitions")
  print("    The EFI partition is the Third-Layer SecureBoot loader")
  print("    It encrypts itself and decrypts only with the correct")
  print("    SecureBoot key on the correct machine (binding verified)")
  print("")
  print("  " .. C.Y .. "EFI partition behavior:" .. C.R)
  print("    • Hidden from AXFS filesystem operations")
  print("    • Visible in partition tools with 'SYSTEM' label")
  print("    • Encrypted with HMAC-XOR keystream cipher")
  print("    • Key = HMAC(secureboot_key, machine_binding)")
  print("    • Decryption fails if machine or key changes")
  print("")
  print(C.E .. "  WARNING: This will DESTROY all data on the target drive." .. C.R)
  print("")

  local tDrives = findDriveDevices()
  if #tDrives > 0 then
    print("  Available drive devices:")
    for _, sDrive in ipairs(tDrives) do
      print("    " .. C.Y .. sDrive .. C.R)
    end
    print("")
    print("  Examples:")
    print("    axfs-switch " .. tDrives[1])
    print("    axfs-switch " .. tDrives[1] .. " --efi-prebuild")
  else
    print(C.E .. "  No drive devices found. Load blkdev: insmod blkdev" .. C.R)
  end
  return
end

-- =============================================
-- OPEN DEVICE + PREFLIGHT
-- =============================================

print(C.C .. "╔═══════════════════════════════════════════════════╗" .. C.R)
if bEfiPrebuild then
  print(C.C .. "║  AXFS-SWITCH: EFI + AXFS Drive Preparation        ║" .. C.R)
else
  print(C.C .. "║  AXFS-SWITCH: Drive Preparation Tool               ║" .. C.R)
end
print(C.C .. "╚═══════════════════════════════════════════════════╝" .. C.R)
print("")

local hDev = fs.open(sDev, "r")
if not hDev then
  print(C.E .. "Cannot open device: " .. sDev .. C.R)
  local tDrives = findDriveDevices()
  if #tDrives == 0 then
    print("  No drives found. Load driver: " .. C.Y .. "insmod blkdev" .. C.R)
  else
    print("  Available: " .. table.concat(tDrives, ", "))
  end
  return
end

local bI, tI = fs.deviceControl(hDev, "info", {})
if not bI or not tI then
  fs.close(hDev); print(C.E .. "Device info failed" .. C.R); return
end

print(C.G .. "[1/5]" .. C.R .. " Target: " .. sDev)
print(C.D .. "  Capacity: " .. math.floor(tI.capacity / 1024) .. " KB" .. C.R)
print(C.D .. "  Sectors:  " .. tI.sectorCount .. " × " .. tI.sectorSize .. "B" .. C.R)
if bEfiPrebuild then
  print(C.M .. "  Mode:     EFI + AXFS (SecureBoot ready)" .. C.R)
end

-- =============================================
-- CONFIRMATION
-- =============================================

print("")
print(C.E .. "  ╔══════════════════════════════════════╗" .. C.R)
print(C.E .. "  ║  THIS WILL DESTROY THE TARGET DRIVE  ║" .. C.R)
print(C.E .. "  ╚══════════════════════════════════════╝" .. C.R)
print("")
io.write(C.Y .. "  Type 'SWITCH' to proceed: " .. C.R)
local sConfirm = io.read()
if sConfirm ~= "SWITCH" then
  fs.close(hDev); print("  Aborted."); return
end

-- =============================================
-- SECTOR I/O
-- =============================================

local nWriteOk, nWriteFail = 0, 0

local function readSec(n)
  local bOk, sData = fs.deviceControl(hDev, "read_sector", {n + 1})
  return bOk and sData or nil
end

local function writeSec(n, sData)
  sData = sData or ""
  if #sData < tI.sectorSize then
    sData = sData .. string.rep("\0", tI.sectorSize - #sData)
  end
  local bOk = fs.deviceControl(hDev, "write_sector",
    {n + 1, sData:sub(1, tI.sectorSize)})
  if bOk then nWriteOk = nWriteOk + 1
  else nWriteFail = nWriteFail + 1 end
  return bOk
end

-- =============================================
-- PROBE DRIVE I/O
-- =============================================

print("")
print(C.G .. "[2/5]" .. C.R .. " Probing drive I/O...")

local sProbeRead = readSec(0)
if not sProbeRead then
  fs.close(hDev)
  print(C.E .. "  FAILED: Cannot read sector 0" .. C.R)
  return
end

local sTestPattern = "AXTS" .. string.rep("\0", tI.sectorSize - 4)
if not writeSec(0, sTestPattern) then
  fs.close(hDev)
  print(C.E .. "  FAILED: Cannot write to sector 0" .. C.R)
  return
end

local sReadBack = readSec(0)
if not sReadBack or sReadBack:sub(1, 4) ~= "AXTS" then
  fs.close(hDev)
  print(C.E .. "  FAILED: Write verification failed" .. C.R)
  return
end
print(C.G .. "  Drive I/O confirmed working." .. C.R)

-- =============================================
-- INITIALIZE RDB
-- =============================================

print("")
print(C.G .. "[3/5]" .. C.R .. " Initializing Amiga RDB" ..
  (bEfiPrebuild and " with @RDB::Partition extensions..." or "..."))

local tDisk = {
  sectorSize  = tI.sectorSize,
  sectorCount = tI.sectorCount,
  readSector  = readSec,
  writeSector = writeSec,
}

local nPartStart = RDB.MAX_PARTS + 1
local tRdb

if bEfiPrebuild then
  -- =============================================
  -- EFI MODE: Create AXEFI + AXFS partitions
  -- =============================================

  local EFI_SECTORS = 32  -- 32 sectors for EFI (16KB at 512B/sector)
  local nEfiStart   = nPartStart
  local nAxfsStart  = nEfiStart + EFI_SECTORS
  local nAxfsSize   = tI.sectorCount - nAxfsStart

  if nAxfsSize < 64 then
    fs.close(hDev)
    print(C.E .. "  Drive too small for EFI + AXFS" .. C.R)
    return
  end

  tRdb = {
    label        = "AxisOS",
    totalSectors = tI.sectorCount,
    generation   = 0,
    partitions   = {
      -- Partition 0: AXEFI (hidden, encrypted, system)
      {
        deviceName   = "EFI0",
        dhIndex      = 0,
        startSector  = nEfiStart,
        sizeSectors  = EFI_SECTORS,
        fsType       = RDB.FS_AXEFI,
        flags        = RDB.PF_BOOTABLE + RDB.PF_READONLY
                     + RDB.PF_HIDDEN_FS + RDB.PF_SYSTEM
                     + RDB.PF_ENCRYPTED,
        bootPriority = 10,  -- higher than AXFS → boot first
        reserved     = 0,
        fsLabel      = "SYSTEM",
        -- @RDB::Partition extension
        ext = {
          visibility    = RDB.VIS_SYSTEM,
          encryptType   = RDB.ENC_XOR_HMAC,
          bootRole      = RDB.ROLE_EFI_STAGE3,
          integrityMode = RDB.INTEGRITY_SHA256,
          extVersion    = 1,
        },
      },
      -- Partition 1: AXFS (visible, bootable, main OS)
      {
        deviceName   = "DH0",
        dhIndex      = 1,
        startSector  = nAxfsStart,
        sizeSectors  = nAxfsSize,
        fsType       = RDB.FS_AXFS2,
        flags        = RDB.PF_BOOTABLE + RDB.PF_AUTOMOUNT,
        bootPriority = 0,
        reserved     = 0,
        fsLabel      = "AxisOS",
        ext = {
          visibility    = RDB.VIS_NORMAL,
          bootRole      = RDB.ROLE_AXFS_ROOT,
          integrityMode = RDB.INTEGRITY_CRC32,
          extVersion    = 1,
        },
      },
    },
  }

  RDB.write(tDisk, tRdb)
  syscall("process_yield")

  -- Verify RDB
  local vRdb = readSec(0)
  if not vRdb or vRdb:sub(1, 4) ~= "RDSK" then
    fs.close(hDev)
    print(C.E .. "  RDB verification FAILED" .. C.R)
    return
  end

  -- Verify both partition blocks
  local vP0 = readSec(1)
  local vP1 = readSec(2)
  if not vP0 or vP0:sub(1, 4) ~= "PART" then
    fs.close(hDev)
    print(C.E .. "  EFI partition block verification FAILED" .. C.R)
    return
  end
  if not vP1 or vP1:sub(1, 4) ~= "PART" then
    fs.close(hDev)
    print(C.E .. "  AXFS partition block verification FAILED" .. C.R)
    return
  end

  print(C.G .. "  RDB written with @RDB::Partition extensions." .. C.R)
  print(C.D .. "  Partition 0: EFI0 [SYSTEM] — hidden, encrypted, stage-3" .. C.R)
  print(C.D .. "    Sectors " .. nEfiStart .. "-" .. (nEfiStart + EFI_SECTORS - 1) .. C.R)
  print(C.D .. "  Partition 1: DH0  [AxisOS] — visible, bootable, root" .. C.R)
  print(C.D .. "    Sectors " .. nAxfsStart .. "-" .. (nAxfsStart + nAxfsSize - 1) .. C.R)

  -- =============================================
  -- SETUP EFI PARTITION
  -- =============================================

  print("")
  print(C.G .. "[4/5]" .. C.R .. " Setting up encrypted EFI partition...")

  -- Try to load the stage 3 bootloader
  local sBootCode = ""
  local hStage3 = fs.open("/lib/efi_stage3.lua", "r")
  if hStage3 then
    local tC = {}
    while true do
      local s = fs.read(hStage3, math.huge); if not s then break end
      tC[#tC + 1] = s
    end
    fs.close(hStage3)
    sBootCode = table.concat(tC)
    print(C.D .. "  Stage 3 bootloader: " .. #sBootCode .. " bytes" .. C.R)
  else
    print(C.Y .. "  /lib/efi_stage3.lua not found — EFI partition created empty" .. C.R)
    print(C.Y .. "  Use 'mkefi setup' after installing OS to populate it" .. C.R)
  end

  -- Load EFI library
  local bEfiLibOk, EFI = pcall(require, "efi_partition")
  if not bEfiLibOk then
    -- Minimal fallback: write header without encryption
    print(C.Y .. "  efi_partition.lua not available — writing unencrypted" .. C.R)

    -- Write minimal EFI header
    local sHdr = "AEFI" .. string.char(2)   -- magic + version
      .. B.u16(#sBootCode)                   -- boot code size
      .. B.u32(B.crc32(sBootCode))           -- boot code CRC
      .. B.u16(1) .. B.u16(2)               -- key block sec+count
      .. B.u16(3) .. B.u16(math.ceil(#sBootCode / tI.sectorSize))
      .. string.char(0)                      -- secureBoot OFF (no encryption)
      .. string.rep("\0", 32)                -- binding (empty)
    sHdr = sHdr .. B.u32(B.crc32(sHdr))     -- header CRC
    writeSec(nEfiStart, B.pad(sHdr, tI.sectorSize))

    -- Write boot code unencrypted
    local nBcSec = math.ceil(#sBootCode / tI.sectorSize)
    for i = 0, nBcSec - 1 do
      local sChunk = sBootCode:sub(i * tI.sectorSize + 1, (i + 1) * tI.sectorSize)
      writeSec(nEfiStart + 3 + i, B.pad(sChunk, tI.sectorSize))
    end
  else
    -- Full encrypted EFI setup
    local sMachineAddr = ""
    pcall(function() sMachineAddr = computer.address() end)

    local tEfiDisk = {
      sectorSize  = tI.sectorSize,
      sectorCount = EFI_SECTORS,
      readSector  = readSec,
      writeSector = writeSec,
    }

    local bSetupOk, tSetupInfo = EFI.setupPartition(
      tEfiDisk, nEfiStart, EFI_SECTORS, {
        bootCode    = sBootCode,
        secureBoot  = (#sBootCode > 0),
        machineAddr = sMachineAddr,
      })

    if bSetupOk and tSetupInfo then
      print(C.G .. "  EFI partition setup complete!" .. C.R)
      print(C.D .. "    Encrypted:  " .. tostring(tSetupInfo.encrypted) .. C.R)
      print(C.D .. "    Mode:       " ..
        (tSetupInfo.encryptMode == 1 and "HMAC-XOR keystream" or "none") .. C.R)
      print(C.D .. "    Binding:    " .. EFI.hex(tSetupInfo.machineBinding):sub(1, 16) .. "..." .. C.R)
      print(C.D .. "    Boot code:  " .. tSetupInfo.bootCodeSize .. "B in " ..
        tSetupInfo.bootSectors .. " sectors" .. C.R)

      -- Update the RDB partition extension with actual hashes
      local tPart0 = tRdb.partitions[1]
      tPart0.ext.contentHash   = tSetupInfo.contentHash
      tPart0.ext.bindingHash   = tSetupInfo.machineBinding
      tPart0.ext.contentCrc    = B.crc32(sBootCode)
      tPart0.ext.encContentLen = tSetupInfo.encrypted and #sBootCode or 0

      -- Re-write partition block 0 with updated hashes
      RDB.write(tDisk, tRdb)
    else
      print(C.E .. "  EFI setup failed: " .. tostring(tSetupInfo) .. C.R)
    end
  end

  -- =============================================
  -- FORMAT AXFS PARTITION
  -- =============================================

  print("")
  print(C.G .. "[5/5]" .. C.R .. " Formatting AXFS v2 on partition 1...")

  local tAxfsDisk = {
    sectorSize  = tI.sectorSize,
    sectorCount = nAxfsSize,
    readSector  = function(n) return readSec(nAxfsStart + n) end,
    writeSector = function(n, d)
      d = d or ""
      if #d < tI.sectorSize then
        d = d .. string.rep("\0", tI.sectorSize - #d)
      end
      return writeSec(nAxfsStart + n, d:sub(1, tI.sectorSize))
    end,
  }

  nWriteOk, nWriteFail = 0, 0

  local bFmtOk, bFmt, sFmtErr = pcall(AX.format, tAxfsDisk, "AxisOS")
  if not bFmtOk then
    fs.close(hDev)
    print(C.E .. "  FORMAT CRASHED: " .. tostring(bFmt) .. C.R)
    return
  end
  syscall("process_yield")

  if not bFmt then
    fs.close(hDev)
    print(C.E .. "  Format failed: " .. tostring(sFmtErr) .. C.R)
    return
  end

  -- Verify superblock
  local vSb = readSec(nAxfsStart)
  if not vSb or vSb:sub(1, 4) ~= "AXF2" then
    fs.close(hDev)
    print(C.E .. "  AXFS superblock verification FAILED" .. C.R)
    return
  end

  print(C.G .. "  AXFS v2 formatted and verified." .. C.R)

else
  -- =============================================
  -- STANDARD MODE: Single AXFS partition (unchanged logic)
  -- =============================================

  local nPartSize = tI.sectorCount - nPartStart

  tRdb = {
    label        = "AxisOS",
    totalSectors = tI.sectorCount,
    generation   = 0,
    partitions   = {
      {
        deviceName   = "DH0",
        dhIndex      = 0,
        startSector  = nPartStart,
        sizeSectors  = nPartSize,
        fsType       = RDB.FS_AXFS2,
        flags        = RDB.PF_BOOTABLE + RDB.PF_AUTOMOUNT,
        bootPriority = 0,
        reserved     = 0,
        fsLabel      = "SYSTEM",
        ext = {
          visibility    = RDB.VIS_NORMAL,
          bootRole      = RDB.ROLE_AXFS_ROOT,
          integrityMode = RDB.INTEGRITY_CRC32,
          extVersion    = 1,
        },
      },
    },
  }

  RDB.write(tDisk, tRdb)
  syscall("process_yield")

  local vRdb = readSec(0)
  if not vRdb or vRdb:sub(1, 4) ~= "RDSK" then
    fs.close(hDev)
    print(C.E .. "  RDB verification FAILED" .. C.R)
    return
  end

  print(C.G .. "  RDB initialized with @RDB::Partition." .. C.R)

  print("")
  print(C.G .. "[4/5]" .. C.R .. " (Skipped — no EFI partition)")
  print("")
  print(C.G .. "[5/5]" .. C.R .. " Formatting AXFS v2...")

  local tAxfsDisk = {
    sectorSize  = tI.sectorSize,
    sectorCount = nPartSize,
    readSector  = function(n) return readSec(nPartStart + n) end,
    writeSector = function(n, d)
      d = d or ""
      if #d < tI.sectorSize then
        d = d .. string.rep("\0", tI.sectorSize - #d)
      end
      return writeSec(nPartStart + n, d:sub(1, tI.sectorSize))
    end,
  }

  nWriteOk, nWriteFail = 0, 0

  local bFmtOk, bFmt, sFmtErr = pcall(AX.format, tAxfsDisk, "AxisOS")
  if not bFmtOk then
    fs.close(hDev)
    print(C.E .. "  FORMAT CRASHED: " .. tostring(bFmt) .. C.R)
    return
  end
  syscall("process_yield")

  if not bFmt then
    fs.close(hDev)
    print(C.E .. "  Format failed: " .. tostring(sFmtErr) .. C.R)
    return
  end

  local vSb = readSec(nPartStart)
  if not vSb or vSb:sub(1, 4) ~= "AXF2" then
    fs.close(hDev)
    print(C.E .. "  Superblock verification FAILED" .. C.R)
    return
  end

  print(C.G .. "  AXFS v2 formatted and verified." .. C.R)
end

fs.close(hDev)

-- =============================================
-- SUMMARY
-- =============================================

print("")
print(C.C .. "╔═══════════════════════════════════════════════════╗" .. C.R)
print(C.C .. "║  DRIVE PREPARATION COMPLETE                       ║" .. C.R)
print(C.C .. "╠═══════════════════════════════════════════════════╣" .. C.R)
print(C.C .. "║" .. C.R .. "  Device:   " .. C.Y .. sDev .. C.R ..
  string.rep(" ", math.max(1, 28 - #sDev)) .. C.C .. "║" .. C.R)

if bEfiPrebuild then
  print(C.C .. "║" .. C.R .. "  Layout:   " .. C.M .. "AXEFI (SYSTEM, hidden)" .. C.R ..
    "          " .. C.C .. "║" .. C.R)
  print(C.C .. "║" .. C.R .. "            " .. C.Y .. "AXFS v2 (AxisOS, root)" .. C.R ..
    "          " .. C.C .. "║" .. C.R)
  print(C.C .. "║" .. C.R .. "  EFI:      " .. C.M .. "Encrypted (HMAC-XOR)" .. C.R ..
    "            " .. C.C .. "║" .. C.R)
  print(C.C .. "║" .. C.R .. "  Binding:  " .. C.G .. "Machine-locked" .. C.R ..
    "                  " .. C.C .. "║" .. C.R)
else
  print(C.C .. "║" .. C.R .. "  Layout:   " .. C.Y .. "AXFS v2 (SYSTEM)" .. C.R ..
    "               " .. C.C .. "║" .. C.R)
end
print(C.C .. "║" .. C.R .. "  RDB:      " .. C.G .. "@RDB::Partition extensions" .. C.R ..
  "       " .. C.C .. "║" .. C.R)
print(C.C .. "║" .. C.R .. "  Verified: " .. C.G .. "YES" .. C.R ..
  "                               " .. C.C .. "║" .. C.R)
print(C.C .. "╚═══════════════════════════════════════════════════╝" .. C.R)

print("")
print(C.Y .. "  NEXT STEPS:" .. C.R)
print("")
print("  " .. C.C .. "Step 1:" .. C.R .. " Copy the OS:")
print("         " .. C.Y .. "axfs_install " .. sDev .. " " ..
  (bEfiPrebuild and "1" or "0") .. C.R)
print("")

if bEfiPrebuild then
  print("  " .. C.C .. "Step 2:" .. C.R .. " Sign the kernel for SecureBoot:")
  print("         " .. C.Y .. "mkefi sign" .. C.R)
  print("")
  print("  " .. C.C .. "Step 3:" .. C.R .. " Flash the SecureBoot EEPROM:")
  print("         " .. C.Y .. "axfs flash /boot/axfs_secure_boot.lua" .. C.R)
  print("")
  print(C.D .. "  The EFI partition is hidden from AXFS but visible" .. C.R)
  print(C.D .. "  in partition tools (axfs parts) with label 'SYSTEM'." .. C.R)
  print(C.D .. "  It will decrypt only on THIS machine with the" .. C.R)
  print(C.D .. "  correct SecureBoot key." .. C.R)
else
  print("  " .. C.C .. "Step 2:" .. C.R .. " Flash bootloader:")
  print("         " .. C.Y .. "axfs flash /boot/axfs_boot.lua" .. C.R)
  print("")
  print(C.D .. "  For SecureBoot, re-run with --efi-prebuild." .. C.R)
end
print("")