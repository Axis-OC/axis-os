--
-- /lib/rdb.lua
-- Amiga-style Rigid Disk Block partition table for AxisOS
-- v2: @RDB::Partition — extended partition metadata
--
-- Self-describing, checksummed, linked-list partitions.
-- Extended fields in bytes 96-255 of each partition block
-- are marked with "AXPX" magic and carry:
--   visibility, encryption state, boot chain role,
--   content hash, machine binding, encrypted key material.
--
-- Standard Amiga RDB parsers ignore bytes 96+, so these
-- extensions are transparent to non-AxisOS tools.
--
local B = require("bpack")
local RDB = {}

-- =============================================
-- MAGIC IDENTIFIERS
-- =============================================

RDB.RDSK = "RDSK"
RDB.PART = "PART"
RDB.FSHD = "FSHD"
RDB.BADB = "BADB"
RDB.AXPX = "AXPX"  -- @RDB::Partition extension magic

RDB.VERSION      = 2
RDB.MAX_PARTS    = 16
RDB.BLOCK_LONGS  = 64
RDB.BLOCK_BYTES  = 256

-- Filesystem type IDs (Amiga DosType style)
RDB.FS_RAW       = 0x00000000
RDB.FS_AXFS1     = 0x41584631  -- "AXF1"
RDB.FS_AXFS2     = 0x41584632  -- "AXF2"
RDB.FS_AXEFI     = 0x41584546  -- "AXEF"
RDB.FS_FAT       = 0x46415400  -- "FAT\0"
RDB.FS_SWAP      = 0x53575000  -- "SWP\0"

-- Standard partition flags (Amiga-compatible)
RDB.PF_BOOTABLE  = 0x01
RDB.PF_AUTOMOUNT = 0x02
RDB.PF_READONLY  = 0x04

-- @RDB::Partition extended flags
RDB.PF_HIDDEN_FS = 0x08  -- hidden from AXFS directory/resolve
RDB.PF_SYSTEM    = 0x10  -- shown as "SYSTEM" in partition tools
RDB.PF_ENCRYPTED = 0x20  -- content is encrypted

-- @RDB::Partition visibility modes
RDB.VIS_NORMAL     = 0   -- visible everywhere
RDB.VIS_HIDDEN_FS  = 1   -- hidden from FS, visible to parted/partition tools
RDB.VIS_SYSTEM     = 2   -- hidden from FS, "SYSTEM" label in tools

-- @RDB::Partition encryption types
RDB.ENC_NONE       = 0
RDB.ENC_XOR_HMAC   = 1   -- XOR with HMAC-SHA256 keystream
RDB.ENC_DATA_CARD  = 2   -- OC data card encrypt() (Tier 2+)

-- @RDB::Partition boot chain roles
RDB.ROLE_DATA      = 0
RDB.ROLE_EFI_STAGE3 = 1
RDB.ROLE_RECOVERY  = 2
RDB.ROLE_SWAP      = 3
RDB.ROLE_AXFS_ROOT = 4

-- @RDB::Partition integrity modes
RDB.INTEGRITY_NONE     = 0
RDB.INTEGRITY_CRC32    = 1
RDB.INTEGRITY_SHA256   = 2

-- =============================================
-- @RDB::Partition EXTENSION STRUCTURE
-- Packed into partition block bytes 97-256 (1-indexed)
--
-- [97-100]   extMagic      "AXPX"
-- [101]      visibility    VIS_*
-- [102]      encryptType   ENC_*
-- [103]      bootRole      ROLE_*
-- [104]      integrityMode INTEGRITY_*
-- [105-136]  contentHash   32 bytes: SHA-256 of decrypted content
-- [137-168]  bindingHash   32 bytes: expected machine binding
-- [169-200]  encKeyMat     32 bytes: encrypted key material
-- [201-204]  contentCrc    CRC32 of decrypted content
-- [205-208]  encContentLen encrypted content byte count
-- [209-212]  extFlags2     additional flags (reserved)
-- [213-216]  extVersion    extension version number
-- [217-248]  extReserved   32 bytes reserved
-- [249-252]  extCrc        CRC32 of bytes 97-248
-- [253-256]  padding
-- =============================================

local function _packPartExt(t)
  local s = RDB.AXPX                                    -- [1-4] magic
    .. B.u8(t.visibility or RDB.VIS_NORMAL)              -- [5]
    .. B.u8(t.encryptType or RDB.ENC_NONE)               -- [6]
    .. B.u8(t.bootRole or RDB.ROLE_DATA)                 -- [7]
    .. B.u8(t.integrityMode or RDB.INTEGRITY_NONE)       -- [8]
    .. B.pad(t.contentHash or "", 32)                    -- [9-40]
    .. B.pad(t.bindingHash or "", 32)                    -- [41-72]
    .. B.pad(t.encKeyMat or "", 32)                      -- [73-104]
    .. B.u32(t.contentCrc or 0)                          -- [105-108]
    .. B.u32(t.encContentLen or 0)                       -- [109-112]
    .. B.u32(t.extFlags2 or 0)                           -- [113-116]
    .. B.u32(t.extVersion or 1)                          -- [117-120]
    .. B.pad("", 32)                                     -- [121-152] reserved
  -- CRC of everything so far (152 bytes)
  s = s .. B.u32(B.crc32(s))                             -- [153-156]
  s = s .. B.pad("", 4)                                  -- [157-160] padding
  return B.pad(s, 160)  -- total extension: 160 bytes
end

local function _unpackPartExt(s)
  if not s or #s < 160 then return nil end
  if s:sub(1, 4) ~= RDB.AXPX then return nil end

  -- Verify extension CRC
  local nStoredCrc = B.r32(s, 153)
  local nCalcCrc = B.crc32(s:sub(1, 152))
  local bCrcValid = (nStoredCrc == nCalcCrc)

  return {
    _valid        = bCrcValid,
    visibility    = B.r8(s, 5),
    encryptType   = B.r8(s, 6),
    bootRole      = B.r8(s, 7),
    integrityMode = B.r8(s, 8),
    contentHash   = s:sub(9, 40),
    bindingHash   = s:sub(41, 72),
    encKeyMat     = s:sub(73, 104),
    contentCrc    = B.r32(s, 105),
    encContentLen = B.r32(s, 109),
    extFlags2     = B.r32(s, 113),
    extVersion    = B.r32(s, 117),
  }
end

-- =============================================
-- RIGID DISK BLOCK (sector 0)
-- =============================================

local function _packRDB(t, nSS)
  local s = RDB.RDSK
    .. B.u32(RDB.BLOCK_LONGS)
    .. B.u32(0)                         -- ChkSum placeholder
    .. B.u32(7)                         -- HostID
    .. B.u32(nSS)
    .. B.u32(t.flags or 0)
    .. B.i32(t.partList or -1)
    .. B.i32(-1)                        -- FileSysHdrList
    .. B.i32(-1)                        -- BadBlockList
    .. B.i32(-1)                        -- DriveInit
    .. B.u32(t.cylinders or 1)
    .. B.u32(t.sectors or 1)
    .. B.u32(t.heads or 1)
    .. B.u32(t.loCyl or 1)
    .. B.u32(t.hiCyl or 0)
    .. B.u32(t.cylBlocks or 1)
    .. B.str(t.vendor or "AxisOS", 16)
    .. B.str(t.product or "UnmanagedDrive", 16)
    .. B.str(t.revision or "v2", 4)
    .. B.str(t.label or "AxisDisk", 16)
    .. B.u32(t.totalSectors or 0)
    .. B.u32(t.generation or 0)

  s = B.pad(s, RDB.BLOCK_BYTES)
  local nChk = B.amiga_checksum(s, 9)
  s = s:sub(1, 8) .. B.u32(nChk) .. s:sub(13)
  return B.pad(s, nSS)
end

local function _unpackRDB(s)
  if not s or #s < RDB.BLOCK_BYTES then return nil, "Too short" end
  if s:sub(1, 4) ~= RDB.RDSK then return nil, "Not an RDB" end
  if not B.amiga_verify(s:sub(1, RDB.BLOCK_BYTES), 9) then
    return nil, "RDB checksum invalid"
  end
  return {
    summedLongs  = B.r32(s, 5),
    hostID       = B.r32(s, 13),
    blockBytes   = B.r32(s, 17),
    flags        = B.r32(s, 21),
    partList     = B.ri32(s, 25),
    cylinders    = B.r32(s, 41),
    sectors      = B.r32(s, 45),
    heads        = B.r32(s, 49),
    loCyl        = B.r32(s, 53),
    hiCyl        = B.r32(s, 57),
    cylBlocks    = B.r32(s, 61),
    vendor       = B.rstr(s, 65, 16),
    product      = B.rstr(s, 81, 16),
    revision     = B.rstr(s, 97, 4),
    label        = B.rstr(s, 101, 16),
    totalSectors = B.r32(s, 117),
    generation   = B.r32(s, 121),
  }
end

-- =============================================
-- PARTITION BLOCK (linked list entries)
-- Standard Amiga fields: bytes 1-96
-- @RDB::Partition extension: bytes 97-256
-- =============================================

local function _packPart(t, nSS)
  local sDevName = t.deviceName or ("DH" .. (t.dhIndex or 0))
  local sBcpl = string.char(#sDevName) .. sDevName

  -- Standard Amiga partition fields (96 bytes)
  local s = RDB.PART
    .. B.u32(RDB.BLOCK_LONGS)
    .. B.u32(0)                           -- ChkSum placeholder
    .. B.u32(7)                           -- HostID
    .. B.i32(t.next or -1)
    .. B.u32(t.flags or RDB.PF_AUTOMOUNT)
    .. B.str(sBcpl, 32)
    .. B.u32(t.startSector or 0)
    .. B.u32(t.sizeSectors or 0)
    .. B.u32(t.fsType or RDB.FS_RAW)
    .. B.i32(t.bootPriority or 0)
    .. B.u32(t.reserved or 0)
    .. B.u32(t.dhIndex or 0)
    .. B.str(t.fsLabel or "", 16)

  -- Pad standard area to 96 bytes
  s = B.pad(s, 96)

  -- @RDB::Partition extension (bytes 97-256)
  local tExt = t.ext or {}
  -- Auto-populate extension from partition flags
  if bit32.band(t.flags or 0, RDB.PF_HIDDEN_FS) ~= 0 then
    tExt.visibility = tExt.visibility or RDB.VIS_HIDDEN_FS
  end
  if bit32.band(t.flags or 0, RDB.PF_SYSTEM) ~= 0 then
    tExt.visibility = tExt.visibility or RDB.VIS_SYSTEM
  end
  if bit32.band(t.flags or 0, RDB.PF_ENCRYPTED) ~= 0 then
    tExt.encryptType = tExt.encryptType or RDB.ENC_XOR_HMAC
  end
  if t.fsType == RDB.FS_AXEFI then
    tExt.bootRole = tExt.bootRole or RDB.ROLE_EFI_STAGE3
  end

  s = s .. _packPartExt(tExt)

  -- Pad to block size
  s = B.pad(s, RDB.BLOCK_BYTES)

  -- Amiga checksum (covers entire 256-byte block)
  local nChk = B.amiga_checksum(s, 9)
  s = s:sub(1, 8) .. B.u32(nChk) .. s:sub(13)
  return B.pad(s, nSS)
end

local function _unpackPart(s)
  if not s or #s < RDB.BLOCK_BYTES then return nil end
  if s:sub(1, 4) ~= RDB.PART then return nil end
  if not B.amiga_verify(s:sub(1, RDB.BLOCK_BYTES), 9) then return nil end

  local nNameLen = s:byte(25) or 0
  if nNameLen > 30 then nNameLen = 30 end
  local sDevName = s:sub(26, 25 + nNameLen)

  local tPart = {
    next         = B.ri32(s, 17),
    flags        = B.r32(s, 21),
    deviceName   = sDevName,
    startSector  = B.r32(s, 57),
    sizeSectors  = B.r32(s, 61),
    fsType       = B.r32(s, 65),
    bootPriority = B.ri32(s, 69),
    reserved     = B.r32(s, 73),
    dhIndex      = B.r32(s, 77),
    fsLabel      = B.rstr(s, 81, 16),
    ext          = nil,
  }

  -- Try to parse @RDB::Partition extension
  if #s >= 256 then
    local tExt = _unpackPartExt(s:sub(97))
    if tExt then
      tPart.ext = tExt
    end
  end

  return tPart
end

-- =============================================
-- PUBLIC: WRITE / READ (unchanged API, extended internals)
-- =============================================

function RDB.write(tDisk, tRdb)
  local ss = tDisk.sectorSize
  local nParts = #(tRdb.partitions or {})

  local nTotal = tRdb.totalSectors or tDisk.sectorCount
  local nHeads = 1
  local nSectorsPerTrack = math.min(nTotal, 64)
  local nCylinders = math.ceil(nTotal / (nHeads * nSectorsPerTrack))

  local tHdr = {
    flags = 0,
    partList = nParts > 0 and 1 or -1,
    cylinders = nCylinders,
    sectors = nSectorsPerTrack,
    heads = nHeads,
    loCyl = 0,
    hiCyl = nCylinders - 1,
    cylBlocks = nSectorsPerTrack * nHeads,
    vendor = "AxisOS",
    product = "UnmanagedDrive",
    revision = "v2",
    label = tRdb.label or "AxisDisk",
    totalSectors = nTotal,
    generation = (tRdb.generation or 0) + 1,
  }

  for i, p in ipairs(tRdb.partitions) do
    p.next = (i < nParts) and (i + 1) or -1
    p.dhIndex = p.dhIndex or (i - 1)
    p.deviceName = p.deviceName or ("DH" .. p.dhIndex)
    tDisk.writeSector(i, _packPart(p, ss))
  end

  for i = nParts + 1, RDB.MAX_PARTS do
    tDisk.writeSector(i, B.pad("", ss))
  end

  tDisk.writeSector(0, _packRDB(tHdr, ss))
  tRdb.generation = tHdr.generation
  return true
end

function RDB.read(tDisk)
  local sH = tDisk.readSector(0)
  if not sH then return nil, "Read error" end
  local tH, sE = _unpackRDB(sH)
  if not tH then return nil, sE end

  local tRdb = {
    label        = tH.label,
    sectorSize   = tH.blockBytes,
    totalSectors = tH.totalSectors,
    generation   = tH.generation,
    cylinders    = tH.cylinders,
    sectors      = tH.sectors,
    heads        = tH.heads,
    vendor       = tH.vendor,
    product      = tH.product,
    partitions   = {},
    devices      = {},
  }

  local nSec = tH.partList
  local nSafety = 0
  while nSec >= 0 and nSafety < RDB.MAX_PARTS do
    local sP = tDisk.readSector(nSec)
    if not sP then break end
    local p = _unpackPart(sP)
    if not p then break end
    p._sector = nSec
    tRdb.partitions[#tRdb.partitions + 1] = p
    local sName = p.deviceName or ("DH" .. (p.dhIndex or #tRdb.partitions - 1))
    tRdb.devices[sName .. ":"] = #tRdb.partitions
    nSec = p.next
    nSafety = nSafety + 1
  end

  return tRdb
end

-- =============================================
-- @RDB::Partition QUERY HELPERS
-- =============================================

-- Check if a partition is hidden from filesystem operations
function RDB.isHiddenFromFS(p)
  if not p then return false end
  -- Check flag first
  if bit32.band(p.flags or 0, RDB.PF_HIDDEN_FS) ~= 0 then return true end
  -- Check extension
  if p.ext and p.ext._valid then
    return p.ext.visibility == RDB.VIS_HIDDEN_FS
        or p.ext.visibility == RDB.VIS_SYSTEM
  end
  return false
end

-- Check if a partition is the EFI stage-3 bootloader
function RDB.isEfiPartition(p)
  if not p then return false end
  if p.fsType == RDB.FS_AXEFI then return true end
  if p.ext and p.ext._valid and p.ext.bootRole == RDB.ROLE_EFI_STAGE3 then
    return true
  end
  return false
end

-- Check if a partition's content is encrypted
function RDB.isEncrypted(p)
  if not p then return false end
  if bit32.band(p.flags or 0, RDB.PF_ENCRYPTED) ~= 0 then return true end
  if p.ext and p.ext._valid then
    return p.ext.encryptType ~= RDB.ENC_NONE
  end
  return false
end

-- Get display label for partition tools (parted-style)
function RDB.getDisplayLabel(p)
  if not p then return "?" end
  if RDB.isEfiPartition(p) then
    return "SYSTEM"
  end
  return p.fsLabel or p.deviceName or "?"
end

-- Find the EFI partition in an RDB
function RDB.findEfi(tRdb)
  if not tRdb then return nil end
  for i, p in ipairs(tRdb.partitions) do
    if RDB.isEfiPartition(p) then return i, p end
  end
  return nil
end

-- Find the first bootable AXFS partition (skipping hidden/EFI)
function RDB.findAxfsRoot(tRdb)
  if not tRdb then return nil end
  local nBest, nBestPri = nil, -999
  for i, p in ipairs(tRdb.partitions) do
    if not RDB.isEfiPartition(p)
       and (p.fsType == RDB.FS_AXFS2 or p.fsType == RDB.FS_AXFS1)
       and bit32.band(p.flags, RDB.PF_BOOTABLE) ~= 0 then
      if p.bootPriority > nBestPri then
        nBest = i; nBestPri = p.bootPriority
      end
    end
  end
  return nBest
end

-- Get all visible partitions (for AXFS proxy list/resolve)
function RDB.visiblePartitions(tRdb)
  local tVis = {}
  for i, p in ipairs(tRdb.partitions) do
    if not RDB.isHiddenFromFS(p) then
      tVis[#tVis + 1] = {index = i, part = p}
    end
  end
  return tVis
end

-- =============================================
-- EXISTING HELPERS (unchanged)
-- =============================================

function RDB.nextFree(tRdb)
  local nNext = 1 + RDB.MAX_PARTS
  for _, p in ipairs(tRdb.partitions) do
    local nEnd = p.startSector + p.sizeSectors
    if nEnd > nNext then nNext = nEnd end
  end
  return nNext
end

function RDB.findBoot(tRdb)
  local nBest, nBestPri = nil, -999
  for i, p in ipairs(tRdb.partitions) do
    if bit32.band(p.flags, RDB.PF_BOOTABLE) ~= 0 then
      if p.bootPriority > nBestPri then
        nBest = i; nBestPri = p.bootPriority
      end
    end
  end
  return nBest
end

function RDB.resolvePath(tRdb, sFullPath)
  local sDevice, sPath = sFullPath:match("^(%w+:)(.*)")
  if not sDevice then return nil, nil, "No device prefix" end
  local nIdx = tRdb.devices[sDevice]
  if not nIdx then return nil, nil, "Unknown device: " .. sDevice end
  if not sPath or sPath == "" then sPath = "/" end
  if sPath:sub(1,1) ~= "/" then sPath = "/" .. sPath end
  return nIdx, sPath
end

function RDB.fsTypeName(nType)
  if nType == RDB.FS_AXFS2 then return "AXFS v2"
  elseif nType == RDB.FS_AXFS1 then return "AXFS v1"
  elseif nType == RDB.FS_AXEFI then return "AXEFI"
  elseif nType == RDB.FS_FAT then return "FAT"
  elseif nType == RDB.FS_SWAP then return "Swap"
  elseif nType == RDB.FS_RAW then return "Raw"
  else return string.format("0x%08X", nType) end
end

return RDB