--
-- /lib/rdb.lua
-- Amiga-style RDB partition table for AxisOS
--
local B = require("bpack")
local RDB = {}

RDB.MAGIC = "AXRD"
RDB.PT_MAGIC = "AXPT"
RDB.VERSION = 1
RDB.MAX_PARTS = 8

-- Header: sector 0
-- 0-3:magic 4:ver 5-6:ss 7-10:total 11:nparts 12-27:label 28-31:checksum

function RDB.packHeader(t, nSS)
  local s = RDB.MAGIC .. string.char(RDB.VERSION)
    .. B.u16(t.sectorSize) .. B.u32(t.totalSectors)
    .. string.char(#t.partitions) .. B.str(t.label, 16) .. "\0\0\0\0"
  return B.pad(s, nSS)
end

function RDB.readHeader(s)
  if #s < 32 or s:sub(1,4) ~= RDB.MAGIC then return nil, "No RDB" end
  return {
    version = s:byte(5),
    sectorSize = B.r16(s,6),
    totalSectors = B.r32(s,8),
    nParts = s:byte(12),
    label = B.rstr(s,13,16),
  }
end

-- Partition entry: sectors 1..1+MAX_PARTS
-- 0-3:magic 4:idx 5-20:name 21-28:fstype 29-32:start 33-36:size 37:flags 38:bootpri

function RDB.packPart(t, nSS)
  local s = RDB.PT_MAGIC .. string.char(t.index or 0)
    .. B.str(t.name or "PART", 16) .. B.str(t.fsType or "raw", 8)
    .. B.u32(t.startSector) .. B.u32(t.sizeInSectors)
    .. string.char(t.flags or 0) .. string.char(t.bootPriority or 0)
  return B.pad(s, nSS)
end

function RDB.readPart(s)
  if #s < 40 or s:sub(1,4) ~= RDB.PT_MAGIC then return nil end
  return {
    index = s:byte(5),
    name = B.rstr(s,6,16),
    fsType = B.rstr(s,22,8),
    startSector = B.r32(s,30),
    sizeInSectors = B.r32(s,34),
    flags = s:byte(38),
    bootPriority = s:byte(39),
  }
end

function RDB.write(tDisk, tRdb)
  tDisk.writeSector(0, RDB.packHeader(tRdb, tDisk.sectorSize))
  for i = 1, RDB.MAX_PARTS do
    local p = tRdb.partitions[i]
    if p then p.index = i-1; tDisk.writeSector(i, RDB.packPart(p, tDisk.sectorSize))
    else tDisk.writeSector(i, B.pad("", tDisk.sectorSize)) end
  end
  return true
end

function RDB.read(tDisk)
  local sH = tDisk.readSector(0)
  if not sH then return nil, "Read error" end
  local tH, sE = RDB.readHeader(sH)
  if not tH then return nil, sE end
  local tRdb = {
    label = tH.label, sectorSize = tH.sectorSize,
    totalSectors = tH.totalSectors, partitions = {},
  }
  for i = 1, tH.nParts do
    local sP = tDisk.readSector(i)
    if sP then
      local p = RDB.readPart(sP)
      if p then table.insert(tRdb.partitions, p) end
    end
  end
  return tRdb
end

-- Calculate next free sector after RDB + existing partitions
function RDB.nextFree(tRdb)
  local nNext = 1 + RDB.MAX_PARTS  -- after header + partition slots
  for _, p in ipairs(tRdb.partitions) do
    local nEnd = p.startSector + p.sizeInSectors
    if nEnd > nNext then nNext = nEnd end
  end
  return nNext
end

return RDB