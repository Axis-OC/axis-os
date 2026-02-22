--
-- /lib/axfs_core.lua
-- AXFS v3: Performance + Integrity
--
-- Over v2:
--   CLOCK sector cache, inode/path/dir-hash caches, inode preload,
--   batch reads, readahead, CoW writes, per-block CRC32 checksums,
--   delayed flush, extent status tracking, health reporting
--
local B = require("bpack")
local AX = {}

AX.MAGIC      = "AXF2"
AX.VERSION    = 2
AX.MAX_INODES = 512
AX.INODE_SZ   = 80
AX.DIRENT_SZ  = 32
AX.NAME_MAX   = 27
AX.ROOT_INO   = 1
AX.EXTENT_SZ  = 4
AX.MAX_INLINE = 52
AX.MAX_IEXT   = 13

AX.FREE=0; AX.FILE=1; AX.DIR=2; AX.LINK=3
AX.F_INLINE=0x01; AX.F_CHECKSUM=0x04

-- Extended feature flags (superblock offset 55)
AX.FEAT_CHECKSUMS = 0x01
AX.FEAT_COW       = 0x02

-- =============================================
-- LAYOUT CALCULATOR
-- nCkSec: extra sectors for checksum table (0=disabled)
-- =============================================

local function layout(nSS, nMaxInodes, nTotalSectors, nCkSec)
  nCkSec = nCkSec or 0
  local ips = math.floor(nSS / AX.INODE_SZ)
  local its = math.ceil(nMaxInodes / ips)
  local nIbmpSec = 1
  local nBbmpStart = 3
  local nOverhead = 2 + nIbmpSec + its + nCkSec
  local nEstBlocks = nTotalSectors - nOverhead - 1
  local nBbmpSec = math.max(1, math.ceil(nEstBlocks / (nSS * 8)))
  nOverhead = 2 + nIbmpSec + nBbmpSec + nCkSec + its
  local nMaxBlocks = nTotalSectors - nOverhead
  if nMaxBlocks < 1 then nMaxBlocks = 1 end
  nBbmpSec = math.max(1, math.ceil(nMaxBlocks / (nSS * 8)))
  local nCkStart = nBbmpStart + nBbmpSec
  local nItableStart = nCkStart + nCkSec
  local nDataStart = nItableStart + its
  nMaxBlocks = nTotalSectors - nDataStart
  if nMaxBlocks < 1 then nMaxBlocks = 1 end
  return {
    ips=ips, its=its, ibmpSec=2,
    bbmpStart=nBbmpStart, bbmpSec=nBbmpSec,
    ckStart=nCkStart, ckSec=nCkSec,
    itableStart=nItableStart, dataStart=nDataStart,
    maxBlocks=nMaxBlocks,
    dpb=math.floor(nSS/AX.DIRENT_SZ),
    ppb=math.floor(nSS/AX.EXTENT_SZ),
  }
end

-- =============================================
-- DISK WRAPPERS (with batch read)
-- =============================================

function AX.wrapDrive(oProxy, nOff, nCnt)
  local ss = oProxy.getSectorSize()
  nOff = nOff or 0
  nCnt = nCnt or math.floor(oProxy.getCapacity()/ss)
  local function rs(n) return oProxy.readSector(nOff+n+1) end
  local function ws(n,d) d=B.pad(d,ss); return oProxy.writeSector(nOff+n+1,d:sub(1,ss)) end
  return {
    sectorSize=ss, sectorCount=nCnt,
    readSector=rs, writeSector=ws,
    batchRead=function(tS)
      local r={}; for i,n in ipairs(tS) do r[i]=rs(n) end; return r
    end,
  }
end

function AX.wrapDevice(hDev, oFs, nOff, nCnt)
  local bI,tI = oFs.deviceControl(hDev,"info",{})
  if not bI then return nil,"No device info" end
  local ss=tI.sectorSize
  nOff=nOff or 0; nCnt=nCnt or tI.sectorCount
  local function rs(n)
    local b,d = oFs.deviceControl(hDev,"read_sector",{nOff+n+1})
    return b and d or nil
  end
  local function ws(n,d)
    d=B.pad(d,ss)
    return oFs.deviceControl(hDev,"write_sector",{nOff+n+1,d:sub(1,ss)})
  end
  return {
    sectorSize=ss, sectorCount=nCnt,
    readSector=rs, writeSector=ws,
    batchRead=function(tS)
      local bOk,tR = oFs.deviceControl(hDev,"batch_read",{tS})
      if bOk and tR then return tR end
      local r={}; for i,n in ipairs(tS) do r[i]=rs(n) end; return r
    end,
  }
end

-- =============================================
-- CLOCK SECTOR CACHE
-- Frequency-biased circular eviction.
-- Hit: increment freq (O(1))
-- Miss: scan from hand, decrement freq, evict first freq==0 (amortized O(1))
-- =============================================

local function newClockCache(nMax)
  return {
    _max=nMax, _n=0,
    _map={},       -- [sector] → slot index
    _sec={},       -- [slot] → sector number
    _dat={},       -- [slot] → raw data
    _frq={},       -- [slot] → frequency counter
    _hand=1,
    _hits=0, _misses=0,
  }
end

local function ccGet(cc, n)
  local slot = cc._map[n]
  if slot then
    cc._frq[slot] = cc._frq[slot] + 1
    cc._hits = cc._hits + 1
    return cc._dat[slot]
  end
  cc._misses = cc._misses + 1
  return nil
end

local function ccPut(cc, n, data)
  if cc._map[n] then
    local slot = cc._map[n]
    cc._dat[slot] = data
    cc._frq[slot] = cc._frq[slot] + 1
    return
  end
  if cc._n < cc._max then
    cc._n = cc._n + 1
    cc._sec[cc._n] = n
    cc._dat[cc._n] = data
    cc._frq[cc._n] = 1
    cc._map[n] = cc._n
    return
  end
  -- Evict: CLOCK scan
  local hand = cc._hand
  for _ = 1, cc._max * 3 do
    if cc._frq[hand] <= 0 then
      -- Evict this slot
      cc._map[cc._sec[hand]] = nil
      cc._sec[hand] = n
      cc._dat[hand] = data
      cc._frq[hand] = 1
      cc._map[n] = hand
      cc._hand = (hand % cc._max) + 1
      return
    end
    cc._frq[hand] = cc._frq[hand] - 1
    hand = (hand % cc._max) + 1
  end
  -- Fallback: force evict current hand
  cc._map[cc._sec[cc._hand]] = nil
  cc._sec[cc._hand] = n
  cc._dat[cc._hand] = data
  cc._frq[cc._hand] = 1
  cc._map[n] = cc._hand
  cc._hand = (cc._hand % cc._max) + 1
end

local function ccInvalidate(cc, n)
  local slot = cc._map[n]
  if slot then
    cc._map[n] = nil
    cc._frq[slot] = 0
  end
end

local function ccStats(cc)
  return {hits=cc._hits, misses=cc._misses,
    entries=cc._n, maxEntries=cc._max,
    hitRate=cc._hits > 0 and
      math.floor(cc._hits/(cc._hits+cc._misses)*100) or 0}
end

-- =============================================
-- BITMAP OPS
-- =============================================

local function bget(s,n)
  local by=math.floor(n/8)+1; local bi=n%8
  if by>#s then return false end
  return math.floor(s:byte(by)/(2^bi))%2==1
end
local function bset(s,n,v)
  local by=math.floor(n/8)+1; local bi=n%8
  while by>#s do s=s.."\0" end
  local o=s:byte(by); local m=2^bi
  local nw
  if v then nw=o+m*(1-math.floor(o/m)%2)
  else nw=o-m*(math.floor(o/m)%2) end
  return s:sub(1,by-1)..string.char(nw)..s:sub(by+1)
end
local function bfree(s,mx)
  for i=0,mx-1 do if not bget(s,i) then return i end end
end

-- =============================================
-- EXTENT PACK/UNPACK
-- =============================================

local function pext(a,b) return B.u16(a)..B.u16(b) end
local function rext(s,o) o=o or 1; return B.r16(s,o),B.r16(s,o+2) end

-- =============================================
-- INODE PACK/UNPACK (80 bytes)
-- =============================================

local function pinode(t)
  local s = B.u16(t.iType or 0)..B.u16(t.mode or 0x1FF)
    ..B.u16(t.uid or 0)..B.u16(t.gid or 0)
    ..B.u32(t.size or 0)
    ..B.u32(t.ctime or 0)..B.u32(t.mtime or 0)
    ..B.u16(t.links or 1)
    ..B.u8(t.flags or 0)..B.u8(t.nExtents or 0)
  if bit32.band(t.flags or 0, AX.F_INLINE) ~= 0 then
    s = s..B.pad(t.inlineData or "", AX.MAX_INLINE)
  else
    for i=1,AX.MAX_IEXT do
      local ext=t.extents and t.extents[i]
      if ext then s=s..pext(ext[1],ext[2]) else s=s..pext(0,0) end
    end
  end
  s = s..B.u16(t.indirect or 0)
  s = s..B.u16(B.crc16(s))
  return B.pad(s, AX.INODE_SZ)
end

local function rinode(s, o)
  o=o or 1
  if #s < o+AX.INODE_SZ-1 then return nil end
  local fl=s:byte(o+22); local ne=s:byte(o+23)
  local t={
    iType=B.r16(s,o), mode=B.r16(s,o+2),
    uid=B.r16(s,o+4), gid=B.r16(s,o+6),
    size=B.r32(s,o+8),
    ctime=B.r32(s,o+12), mtime=B.r32(s,o+16),
    links=B.r16(s,o+20), flags=fl, nExtents=ne,
    extents={}, indirect=B.r16(s,o+76), inlineData=nil,
  }
  if bit32.band(fl,AX.F_INLINE)~=0 then
    t.inlineData=s:sub(o+24,o+24+math.min(t.size,AX.MAX_INLINE)-1)
  else
    for i=1,math.min(ne,AX.MAX_IEXT) do
      local eo=o+24+(i-1)*AX.EXTENT_SZ
      local a,b=rext(s,eo)
      if a>0 or b>0 then t.extents[i]={a,b} end
    end
  end
  t._crcValid=(B.crc16(s:sub(o,o+77))==B.r16(s,o+78))
  return t
end

-- =============================================
-- DIRECTORY ENTRY (32 bytes)
-- =============================================

local function pde(ino,tp,nm)
  nm=nm:sub(1,AX.NAME_MAX)
  return B.u16(ino)..string.char(tp,#nm)..B.str(nm,28)
end
local function rde(s,o)
  o=o or 1
  if #s<o+AX.DIRENT_SZ-1 then return nil end
  local nl=s:byte(o+3); if nl>AX.NAME_MAX then nl=AX.NAME_MAX end
  return {inode=B.r16(s,o),iType=s:byte(o+2),name=s:sub(o+4,o+3+nl)}
end

-- =============================================
-- SUPERBLOCK (extended with v3 fields after CRC)
-- =============================================

local function psuper(t, nSS)
  local s = AX.MAGIC
    ..B.u8(AX.VERSION)..B.u16(t.ss)..B.u32(t.ts)
    ..B.u16(t.mi)..B.u16(t.mb)..B.u16(t.fi)..B.u16(t.fb)
    ..B.u16(t.ds)..B.u16(t.itStart)..B.u16(t.bbStart)
    ..B.u8(t.bbSec)..B.str(t.label,16)
    ..B.u32(t.ct)..B.u32(t.mt)..B.u32(t.gen or 0)
    ..B.u16(t.flags or 0)
  s = s..B.u32(B.crc32(s))
  -- Extended fields (after CRC, invisible to v2 readers)
  s = s..B.u16(t.ckStart or 0)    -- [60] checksum table start
  s = s..B.u16(t.ckSec or 0)      -- [62] checksum sector count
  s = s..B.u16(t.extFeats or 0)   -- [64] extended feature flags
  s = s..B.u32(t.cowGen or 0)     -- [66] CoW generation
  s = s..B.u32(t.nTotalWrites or 0) -- [70] write counter
  s = s..B.u32(t.nTotalReads or 0)  -- [74] read counter
  return B.pad(s, nSS)
end

local function rsuper(s)
  if not s or #s<56 then return nil,"Too short" end
  if s:sub(1,4)~=AX.MAGIC then return nil,"Not AXFSv2" end
  if s:byte(5)~=AX.VERSION then return nil,"Version "..s:byte(5) end
  local t={
    ver=s:byte(5), ss=B.r16(s,6), ts=B.r32(s,8),
    mi=B.r16(s,12), mb=B.r16(s,14),
    fi=B.r16(s,16), fb=B.r16(s,18),
    ds=B.r16(s,20), itStart=B.r16(s,22),
    bbStart=B.r16(s,24), bbSec=s:byte(26),
    label=B.rstr(s,27,16),
    ct=B.r32(s,43), mt=B.r32(s,47),
    gen=B.r32(s,51), flags=B.r16(s,55),
  }
  t._crcValid=(B.r32(s,57)==B.crc32(s:sub(1,56)))
  -- Extended (may not exist on v2 volumes)
  if #s >= 78 then
    t.ckStart    = B.r16(s,61)
    t.ckSec      = B.r16(s,63)
    t.extFeats   = B.r16(s,65)
    t.cowGen     = B.r32(s,67)
    t.nTotalWrites = B.r32(s,71)
    t.nTotalReads  = B.r32(s,75)
  end
  return t
end

-- =============================================
-- FORMAT
-- =============================================

function AX.format(tD, sLabel, nMaxInodes, tOpts)
  nMaxInodes = nMaxInodes or AX.MAX_INODES
  tOpts = tOpts or {}
  local ss = tD.sectorSize
  local bChecksums = tOpts.checksums or false
  -- Compute checksum sectors needed
  local nCkSec = 0
  if bChecksums then
    -- Estimate: we need ceil(maxBlocks / (ss/4)) sectors
    -- But maxBlocks depends on nCkSec... iterate once
    local L0 = layout(ss, nMaxInodes, tD.sectorCount, 0)
    nCkSec = math.ceil(L0.maxBlocks / math.floor(ss / 4))
  end
  local L = layout(ss, nMaxInodes, tD.sectorCount, nCkSec)
  if bChecksums then
    -- Recalculate with actual maxBlocks
    nCkSec = math.ceil(L.maxBlocks / math.floor(ss / 4))
    L = layout(ss, nMaxInodes, tD.sectorCount, nCkSec)
  end
  if L.maxBlocks < 1 then return nil,"Disk too small" end
  local now = os.time and os.time() or 0
  local nFlags = 0
  if bChecksums then nFlags = bit32.bor(nFlags, AX.FEAT_CHECKSUMS) end
  if tOpts.cow then nFlags = bit32.bor(nFlags, AX.FEAT_COW) end
  local su={
    ss=ss,ts=tD.sectorCount,mi=nMaxInodes,
    mb=L.maxBlocks,fi=nMaxInodes-2,fb=L.maxBlocks-1,
    ds=L.dataStart,itStart=L.itableStart,
    bbStart=L.bbmpStart,bbSec=L.bbmpSec,
    label=sLabel or "AxisFS",ct=now,mt=now,gen=1,
    flags=nFlags,
    ckStart=L.ckStart, ckSec=nCkSec,
    extFeats=nFlags, cowGen=0,
    nTotalWrites=0, nTotalReads=0,
  }
  local sSup = psuper(su, ss)
  tD.writeSector(0, sSup); tD.writeSector(1, sSup)
  -- Inode bitmap
  local ib = B.pad("",ss)
  ib=bset(ib,0,true); ib=bset(ib,1,true)
  tD.writeSector(L.ibmpSec, ib)
  -- Block bitmap
  local bb = B.pad("",ss)
  for sec=0,L.bbmpSec-1 do
    if sec==0 then bb=bset(bb,0,true); tD.writeSector(L.bbmpStart+sec,bb)
    else tD.writeSector(L.bbmpStart+sec,B.pad("",ss)) end
  end
  -- Checksum table (zero-fill)
  for sec=0,nCkSec-1 do tD.writeSector(L.ckStart+sec,B.pad("",ss)) end
  -- Inode table (zero-fill)
  local ez=B.pad("",ss)
  for i=0,L.its-1 do tD.writeSector(L.itableStart+i,ez) end
  -- Root inode
  local ri={
    iType=AX.DIR,mode=0x1FF,uid=0,gid=0,
    size=AX.DIRENT_SZ*2,ctime=now,mtime=now,
    links=2,flags=0,nExtents=1,extents={{0,1}},indirect=0,
  }
  local riSec=L.itableStart+math.floor(1/L.ips)
  local riOff=(1%L.ips)*AX.INODE_SZ
  local sd=tD.readSector(riSec) or ez
  sd=sd:sub(1,riOff)..pinode(ri)..sd:sub(riOff+AX.INODE_SZ+1)
  tD.writeSector(riSec, B.pad(sd,ss))
  -- Root dir data
  tD.writeSector(L.dataStart, B.pad(pde(1,AX.DIR,"..")..pde(1,AX.DIR,".."),ss))
  -- Fix: root dir entry "." should point to self
  local dd = pde(1,AX.DIR,".")..pde(1,AX.DIR,"..")
  tD.writeSector(L.dataStart, B.pad(dd,ss))
  return true
end

-- =============================================
-- MOUNT
-- =============================================

function AX.mount(tD, tMountOpts)
  tMountOpts = tMountOpts or {}
  local CACHE_MAX = tMountOpts.cacheSize or 128

  -- ── CLOCK sector cache wrapping raw I/O ──
  local cc = newClockCache(CACHE_MAX)
  local fRawRead  = tD.readSector
  local fRawWrite = tD.writeSector
  local fRawBatch = tD.batchRead

  tD.readSector = function(n)
    local d = ccGet(cc, n)
    if d then return d end
    d = fRawRead(n)
    if d then ccPut(cc, n, d) end
    return d
  end
  tD.writeSector = function(n, d)
    ccInvalidate(cc, n)
    return fRawWrite(n, d)
  end
  -- Batch read: check cache first, batch-read only misses
  tD.batchRead = function(tSectors)
    local tResult = {}
    local tMiss = {}
    local tMissIdx = {}
    for i, n in ipairs(tSectors) do
      local d = ccGet(cc, n)
      if d then tResult[i] = d
      else tMiss[#tMiss+1] = n; tMissIdx[#tMissIdx+1] = i end
    end
    if #tMiss > 0 then
      local tRead = fRawBatch and fRawBatch(tMiss)
      if not tRead then
        tRead = {}
        for j, n in ipairs(tMiss) do tRead[j] = fRawRead(n) end
      end
      for j, idx in ipairs(tMissIdx) do
        tResult[idx] = tRead[j]
        if tRead[j] then ccPut(cc, tMiss[j], tRead[j]) end
      end
    end
    return tResult
  end

  -- ── Read superblock ──
  local su, e = rsuper(tD.readSector(0))
  if not su then su,e = rsuper(tD.readSector(1)); if not su then return nil,e end end
  local su2 = rsuper(tD.readSector(1))
  if su2 and su2._crcValid and su2.gen > su.gen then su = su2 end

  local L = layout(tD.sectorSize, su.mi, su.ts, su.ckSec or 0)
  L.dataStart=su.ds; L.itableStart=su.itStart
  L.bbmpStart=su.bbStart; L.bbmpSec=su.bbSec
  L.ckStart=su.ckStart or 0; L.ckSec=su.ckSec or 0

  -- ── Read bitmaps ──
  local sIbmp = tD.readSector(L.ibmpSec)
  local tBbmp = {}
  for i=0,L.bbmpSec-1 do
    tBbmp[i] = tD.readSector(L.bbmpStart+i) or B.pad("",tD.sectorSize)
  end

  -- ── Read checksum table into memory ──
  local tCkTable = {}  -- [blockNum] → CRC32 (number)
  local bHasChecksums = L.ckSec > 0 and
    bit32.band(su.flags or 0, AX.FEAT_CHECKSUMS) ~= 0
  if bHasChecksums then
    local nPerSec = math.floor(tD.sectorSize / 4)
    for sec = 0, L.ckSec - 1 do
      local sd = tD.readSector(L.ckStart + sec)
      if sd then
        for j = 0, nPerSec - 1 do
          local bn = sec * nPerSec + j
          if bn < su.mb then
            tCkTable[bn] = B.r32(sd, j * 4 + 1)
          end
        end
      end
    end
  end

  -- ── Preload inode table sectors into cache ──
  local tITSectors = {}
  for i = 0, L.its - 1 do
    tITSectors[i + 1] = L.itableStart + i
  end
  tD.batchRead(tITSectors)

  -- ── Build volume ──
  local bCow = bit32.band(su.flags or 0, AX.FEAT_COW) ~= 0
  if tMountOpts.cow ~= nil then bCow = tMountOpts.cow end

  local v = {
    d=tD, su=su, L=L,
    ib=sIbmp, tBbmp=tBbmp,
    dirty=false, allocHint=0,
    -- Caches
    _cc=cc,
    _icache={}, _icacheN=0, _icacheMax=128,
    _pcache={}, _pcacheN=0, _pcacheMax=256,
    _dhcache={},  -- [dirIno] → {[name]=inode}
    -- Checksums
    _ck=tCkTable, _bCk=bHasChecksums,
    _ckDirty={}, -- [sectorIdx] → true
    -- CoW
    _bCow=bCow,
    -- Stats
    _nReads=0, _nWrites=0,
    _nCowCopies=0, _nCkFails=0,
  }
  setmetatable(v, {__index=AX._V})
  return v
end

AX._V = {}

-- =============================================
-- CACHE INVALIDATION
-- =============================================

function AX._V:_dirtyMeta()
  self._pcache={}; self._pcacheN=0
  self._dhcache={}
  self._icache={}; self._icacheN=0
  self.dirty=true
end

-- =============================================
-- MEMORY PRESSURE RELIEF
-- Flush dirty data to disk, then drop ALL in-memory caches.
-- Next read will re-populate from disk (cache miss).
-- Call this during bulk operations (install) to keep RSS bounded.
-- =============================================

function AX._V:purgeCache()
  -- Flush dirty state to disk FIRST (bitmaps, superblock).
  -- If flush encounters write errors, retry the critical sectors.
  local bFlushOk = true
  if self.dirty then
    -- Bitmap writes are CRITICAL — a failed bitmap write causes
    -- stale-data corruption after cache clear.  Retry once.
    local function safeWrite(n, d)
      local r = self.d.writeSector(n, d)
      if not r then
        -- Yield to let IPC pipeline drain, then retry
        pcall(function() coroutine.yield() end)
        r = self.d.writeSector(n, d)
      end
      if not r then bFlushOk = false end
      return r
    end

    safeWrite(self.L.ibmpSec, self.ib)
    for i = 0, self.L.bbmpSec - 1 do
      safeWrite(self.L.bbmpStart + i, self.tBbmp[i])
    end
    -- Flush dirty checksum sectors
    if self._bCk then
      local ss = self.d.sectorSize
      local nPerSec = math.floor(ss / 4)
      for secIdx in pairs(self._ckDirty) do
        local sData = ""
        for j = 0, nPerSec - 1 do
          local bn = secIdx * nPerSec + j
          sData = sData .. B.u32(self._ck[bn] or 0)
        end
        safeWrite(self.L.ckStart + secIdx, B.pad(sData, ss))
      end
      self._ckDirty = {}
    end
    self.su.mt = os.time and os.time() or 0
    self.su.gen = (self.su.gen or 0) + 1
    self.su.nTotalWrites = (self.su.nTotalWrites or 0) + self._nWrites
    self.su.nTotalReads = (self.su.nTotalReads or 0) + self._nReads
    local sSup = psuper(self.su, self.d.sectorSize)
    safeWrite(0, sSup); safeWrite(1, sSup)
    self.dirty = false
  end

  -- Phase 1: Nil sector data strings explicitly.
  -- These are the largest objects (cacheSize × sectorSize bytes).
  -- Nilling them makes them eligible for incremental GC immediately,
  -- even before the table objects themselves are collected.
  local cc = self._cc
  for i = 1, cc._n do
    cc._dat[i] = nil
  end
  -- Phase 2: Replace all cache tables with fresh empty ones.
  -- Old tables (with grown internal hash arrays) become garbage.
  cc._map = {}; cc._sec = {}; cc._dat = {}; cc._frq = {}
  cc._n = 0; cc._hand = 1
  self._icache = {}; self._icacheN = 0
  self._pcache = {}; self._pcacheN = 0
  self._dhcache = {}

  return bFlushOk
end

-- =============================================
-- FLUSH / UNMOUNT
-- =============================================

function AX._V:flush()
  if not self.dirty then return end
  self.d.writeSector(self.L.ibmpSec, self.ib)
  for i=0,self.L.bbmpSec-1 do
    self.d.writeSector(self.L.bbmpStart+i, self.tBbmp[i])
  end
  -- Flush dirty checksum sectors
  if self._bCk then
    local ss = self.d.sectorSize
    local nPerSec = math.floor(ss / 4)
    for secIdx in pairs(self._ckDirty) do
      local sData = ""
      for j = 0, nPerSec - 1 do
        local bn = secIdx * nPerSec + j
        sData = sData .. B.u32(self._ck[bn] or 0)
      end
      self.d.writeSector(self.L.ckStart + secIdx, B.pad(sData, ss))
    end
    self._ckDirty = {}
  end
  self.su.mt = os.time and os.time() or 0
  self.su.gen = (self.su.gen or 0) + 1
  self.su.nTotalWrites = (self.su.nTotalWrites or 0) + self._nWrites
  self.su.nTotalReads = (self.su.nTotalReads or 0) + self._nReads
  local sSup = psuper(self.su, self.d.sectorSize)
  self.d.writeSector(0, sSup); self.d.writeSector(1, sSup)
  self.dirty = false
end

function AX._V:unmount() self:flush() end

-- =============================================
-- INODE READ/WRITE (with LRU-ish cache)
-- =============================================

function AX._V:ri(n)
  local c = self._icache[n]
  if c then return c end
  local sec = self.L.itableStart + math.floor(n / self.L.ips)
  local off = (n % self.L.ips) * AX.INODE_SZ
  local sd = self.d.readSector(sec)
  if not sd then return nil end
  local t = rinode(sd, off + 1)
  if t then
    -- LRU eviction: if cache full, remove a random entry
    if self._icacheN >= self._icacheMax then
      local victim = next(self._icache)
      if victim then self._icache[victim]=nil; self._icacheN=self._icacheN-1 end
    end
    self._icache[n]=t; self._icacheN=self._icacheN+1
  end
  return t
end

function AX._V:wi(n, t)
  self._icache[n]=nil
  if self._icacheN > 0 then self._icacheN=self._icacheN-1 end
  local ss=self.d.sectorSize
  local sec=self.L.itableStart+math.floor(n/self.L.ips)
  local off=(n%self.L.ips)*AX.INODE_SZ
  local sd=self.d.readSector(sec) or B.pad("",ss)
  sd=sd:sub(1,off)..pinode(t)..sd:sub(off+AX.INODE_SZ+1)
  self.d.writeSector(sec, B.pad(sd,ss))
end

-- =============================================
-- BLOCK BITMAP (multi-sector)
-- =============================================

local function bbGet(v,n)
  local ss=v.d.sectorSize; local bps=ss*8
  local si=math.floor(n/bps); local bi=n%bps
  local s=v.tBbmp[si]; if not s then return false end
  return bget(s,bi)
end
local function bbSet(v,n,val)
  local ss=v.d.sectorSize; local bps=ss*8
  local si=math.floor(n/bps); local bi=n%bps
  if not v.tBbmp[si] then v.tBbmp[si]=B.pad("",ss) end
  v.tBbmp[si]=bset(v.tBbmp[si],bi,val)
end

-- =============================================
-- ALLOCATORS
-- =============================================

function AX._V:ai()
  local n=bfree(self.ib,self.su.mi)
  if not n then return nil end
  self.ib=bset(self.ib,n,true)
  self.su.fi=self.su.fi-1; self.dirty=true
  return n
end
function AX._V:fi2(n)
  self.ib=bset(self.ib,n,false)
  self.su.fi=self.su.fi+1; self.dirty=true
end

function AX._V:allocExtent(nCount)
  nCount=nCount or 1; local mb=self.su.mb
  for start=self.allocHint,mb-nCount do
    local ok=true
    for j=0,nCount-1 do if bbGet(self,start+j) then ok=false; break end end
    if ok then
      for j=0,nCount-1 do bbSet(self,start+j,true) end
      self.su.fb=self.su.fb-nCount; self.dirty=true
      self.allocHint=start+nCount; return start
    end
  end
  for start=0,math.min(self.allocHint-1,mb-nCount) do
    local ok=true
    for j=0,nCount-1 do if bbGet(self,start+j) then ok=false; break end end
    if ok then
      for j=0,nCount-1 do bbSet(self,start+j,true) end
      self.su.fb=self.su.fb-nCount; self.dirty=true
      self.allocHint=start+nCount; return start
    end
  end
  return nil
end
function AX._V:ab() return self:allocExtent(1) end

function AX._V:freeExtent(s,c)
  for j=0,c-1 do bbSet(self,s+j,false) end
  self.su.fb=self.su.fb+c; self.dirty=true
end
function AX._V:fb(n) if n and n>0 then self:freeExtent(n,1) end end

-- =============================================
-- BLOCK I/O (with checksums)
-- =============================================

function AX._V:b2s(n) return self.su.ds+n end

function AX._V:rb(n)
  local sd = self.d.readSector(self:b2s(n))
  self._nReads = self._nReads + 1
  if sd and self._bCk and self._ck[n] then
    local nExpected = self._ck[n]
    if nExpected ~= 0 then
      local nActual = B.crc32(sd)
      if nActual ~= nExpected then
        self._nCkFails = self._nCkFails + 1
      end
    end
  end
  return sd
end

function AX._V:wb(n, d)
  d = B.pad(d, self.d.sectorSize)
  self._nWrites = self._nWrites + 1
  -- Update checksum
  if self._bCk then
    self._ck[n] = B.crc32(d)
    local nPerSec = math.floor(self.d.sectorSize / 4)
    self._ckDirty[math.floor(n / nPerSec)] = true
  end
  self.d.writeSector(self:b2s(n), d)
end

-- Batch read blocks with readahead for sequential extents
function AX._V:readBlocks(tBlockNums)
  if #tBlockNums == 0 then return {} end
  if #tBlockNums == 1 then return {self:rb(tBlockNums[1])} end
  -- Convert block nums to sector nums
  local tSectors = {}
  for i, bn in ipairs(tBlockNums) do tSectors[i] = self:b2s(bn) end
  local tData = self.d.batchRead(tSectors)
  -- Verify checksums
  if self._bCk then
    for i, bn in ipairs(tBlockNums) do
      if tData[i] and self._ck[bn] and self._ck[bn] ~= 0 then
        if B.crc32(tData[i]) ~= self._ck[bn] then
          self._nCkFails = self._nCkFails + 1
        end
      end
    end
  end
  self._nReads = self._nReads + #tBlockNums
  return tData
end

-- =============================================
-- EXTENT HELPERS (with batch readahead)
-- =============================================

function AX._V:iblocks(t)
  if bit32.band(t.flags or 0,AX.F_INLINE)~=0 then return {} end
  local r={}
  for i=1,math.min(t.nExtents or 0,AX.MAX_IEXT) do
    local ext=t.extents[i]
    if ext and (ext[1]>0 or ext[2]>0) then
      for j=0,ext[2]-1 do r[#r+1]=ext[1]+j end
    end
  end
  if (t.nExtents or 0)>AX.MAX_IEXT and (t.indirect or 0)>0 then
    local si=self:rb(t.indirect)
    if si then
      for i=1,self.L.ppb do
        local eS,eC=rext(si,(i-1)*AX.EXTENT_SZ+1)
        if eC>0 then for j=0,eC-1 do r[#r+1]=eS+j end end
      end
    end
  end
  return r
end

function AX._V:freeIblocks(t)
  if bit32.band(t.flags or 0,AX.F_INLINE)~=0 then return end
  for i=1,math.min(t.nExtents or 0,AX.MAX_IEXT) do
    local ext=t.extents[i]
    if ext and ext[2]>0 then self:freeExtent(ext[1],ext[2]) end
  end
  if (t.nExtents or 0)>AX.MAX_IEXT and (t.indirect or 0)>0 then
    local si=self:rb(t.indirect)
    if si then
      for i=1,self.L.ppb do
        local a,c=rext(si,(i-1)*AX.EXTENT_SZ+1)
        if c>0 then self:freeExtent(a,c) end
      end
    end
    self:fb(t.indirect)
  end
end

-- Read all data from inode using batch readahead
function AX._V:readInodeData(t)
  if bit32.band(t.flags or 0,AX.F_INLINE)~=0 then
    return (t.inlineData or ""):sub(1,t.size)
  end
  local tBlocks = self:iblocks(t)
  if #tBlocks == 0 then return "" end
  -- Batch read ALL data blocks at once
  local tData = self:readBlocks(tBlocks)
  local ch={}; local rem=t.size; local ss=self.d.sectorSize
  for i, sd in ipairs(tData) do
    if sd then ch[#ch+1]=sd:sub(1,math.min(rem,ss)); rem=rem-ss end
    if rem<=0 then break end
  end
  return table.concat(ch)
end

-- =============================================
-- COW WRITE ENGINE
-- Allocate new blocks, write data, update inode, THEN free old.
-- Crash between steps 3 and 4 = leaked blocks (safe, fsck finds them).
-- Crash before step 3 = old data intact (safe).
-- =============================================

function AX._V:writeInodeData(ino, t, data)
  data = data or ""
  local ss = self.d.sectorSize
  local now = os.time and os.time() or 0
  t.size = #data; t.mtime = now

  -- Save old blocks for CoW deferred free
  local tOldBlocks = {}
  if self._bCow then
    tOldBlocks = self:iblocks(t)
  else
    self:freeIblocks(t)
  end

  -- Inline for small files
  if #data <= AX.MAX_INLINE then
    t.flags=bit32.bor(AX.F_INLINE,AX.F_CHECKSUM)
    t.inlineData=data; t.nExtents=0; t.extents={}; t.indirect=0
    self:wi(ino, t)
    -- CoW: free old blocks AFTER inode updated
    if self._bCow then
      for _, bn in ipairs(tOldBlocks) do self:fb(bn) end
      self._nCowCopies = self._nCowCopies + 1
    end
    return true
  end

  -- Extent-based
  t.flags=AX.F_CHECKSUM; t.inlineData=nil
  t.extents={}; t.indirect=0
  local nBlocks=math.ceil(#data/ss)

  -- Allocate new blocks (try contiguous first)
  local tNewExtents = {}
  local nStart = self:allocExtent(nBlocks)
  if nStart then
    tNewExtents[1] = {nStart, nBlocks}
    for i=0,nBlocks-1 do self:wb(nStart+i, data:sub(i*ss+1,(i+1)*ss)) end
  else
    -- Fragmented: allocate progressively smaller extents
    local nWritten, nRem = 0, nBlocks
    while nRem > 0 do
      local nTry=nRem; local nAS=nil
      while nTry>0 do nAS=self:allocExtent(nTry); if nAS then break end; nTry=math.ceil(nTry/2) end
      if not nAS then
        -- Rollback: free what we just allocated
        for _, ext in ipairs(tNewExtents) do self:freeExtent(ext[1],ext[2]) end
        return false,"Disk full"
      end
      tNewExtents[#tNewExtents+1]={nAS,nTry}
      for i=0,nTry-1 do
        local off=(nWritten+i)*ss
        self:wb(nAS+i, data:sub(off+1,off+ss))
      end
      nWritten=nWritten+nTry; nRem=nRem-nTry
    end
  end

  -- Update inode with NEW extent pointers
  t.nExtents=#tNewExtents
  if #tNewExtents<=AX.MAX_IEXT then
    for i=1,#tNewExtents do t.extents[i]=tNewExtents[i] end
  else
    for i=1,AX.MAX_IEXT do t.extents[i]=tNewExtents[i] end
    local ib=self:ab()
    if not ib then return false,"No indirect block" end
    t.indirect=ib
    local sI=""
    for i=AX.MAX_IEXT+1,#tNewExtents do sI=sI..pext(tNewExtents[i][1],tNewExtents[i][2]) end
    self:wb(ib,sI)
  end

  -- COMMIT: write inode (atomic sector write)
  self:wi(ino, t)

  -- CoW: NOW free old blocks (after inode points to new ones)
  if self._bCow and #tOldBlocks > 0 then
    for _, bn in ipairs(tOldBlocks) do self:fb(bn) end
    self._nCowCopies = self._nCowCopies + 1
  end

  return true
end

-- =============================================
-- PATH RESOLUTION (cached, with dir hash)
-- =============================================

function AX._V:split(p)
  local r={}
  for s in p:gmatch("[^/]+") do
    if s==".." then if #r>0 then table.remove(r) end
    elseif s~="." and s~="" then r[#r+1]=s end
  end
  return r
end

-- Build hash table for a directory (O(n) once, then O(1) lookups)
function AX._V:_dirHash(di, nDirIno)
  local cached = self._dhcache[nDirIno]
  if cached then return cached end
  local tHash = {}
  local tBlocks = self:iblocks(di)
  -- Batch read all directory blocks at once
  local tData = self:readBlocks(tBlocks)
  for _, sd in ipairs(tData) do
    if sd then
      for i=0,self.L.dpb-1 do
        local e=rde(sd, i*AX.DIRENT_SZ+1)
        if e and e.inode>0 then
          tHash[e.name] = {inode=e.inode, iType=e.iType}
        end
      end
    end
  end
  self._dhcache[nDirIno] = tHash
  return tHash
end

function AX._V:dlookup(di, nm, nDirIno)
  if nDirIno then
    local tHash = self:_dirHash(di, nDirIno)
    local e = tHash[nm]
    if e then return e.inode, e end
  end
  -- Fallback: linear scan (no dir inode number available)
  local tBlocks = self:iblocks(di)
  for _, bn in ipairs(tBlocks) do
    local sd=self:rb(bn)
    if sd then
      for i=0,self.L.dpb-1 do
        local e=rde(sd,i*AX.DIRENT_SZ+1)
        if e and e.inode>0 and e.name==nm then return e.inode,e end
      end
    end
  end
end

function AX._V:resolve(p)
  -- Path cache
  local cached = self._pcache[p]
  if cached then return cached end
  local parts=self:split(p)
  local c=AX.ROOT_INO
  for _, nm in ipairs(parts) do
    local t=self:ri(c)
    if not t or t.iType~=AX.DIR then return nil,"Not a dir" end
    local ch=self:dlookup(t, nm, c)
    if not ch then return nil,"Not found: "..nm end
    c=ch
  end
  -- Cache result (evict if full)
  if self._pcacheN >= self._pcacheMax then
    local victim = next(self._pcache)
    if victim then self._pcache[victim]=nil; self._pcacheN=self._pcacheN-1 end
  end
  self._pcache[p]=c; self._pcacheN=self._pcacheN+1
  return c
end

function AX._V:rpar(p)
  local parts=self:split(p)
  if #parts==0 then return AX.ROOT_INO,"" end
  local base=table.remove(parts)
  local c=AX.ROOT_INO
  for _, nm in ipairs(parts) do
    local t=self:ri(c)
    if not t or t.iType~=AX.DIR then return nil,nil,"Bad path" end
    local ch=self:dlookup(t, nm, c)
    if not ch then return nil,nil,"Not found: "..nm end
    c=ch
  end
  return c,base
end

-- =============================================
-- DIRECTORY OPS (invalidate hash cache on write)
-- =============================================

function AX._V:dadd(di, ci, ct, nm)
  local dt=self:ri(di); if not dt then return false end
  local ent=pde(ci,ct,nm); local dpb=self.L.dpb
  local tBlocks=self:iblocks(dt)
  for _, bn in ipairs(tBlocks) do
    local sd=self:rb(bn)
    if sd then
      for i=0,dpb-1 do
        local o=i*AX.DIRENT_SZ; local e=rde(sd,o+1)
        if not e or e.inode==0 then
          sd=sd:sub(1,o)..ent..sd:sub(o+AX.DIRENT_SZ+1)
          self:wb(bn,sd)
          dt.mtime=os.time and os.time() or 0
          dt.size=dt.size+AX.DIRENT_SZ
          self:wi(di,dt); self:_dirtyMeta(); return true
        end
      end
    end
  end
  local nb=self:ab()
  if not nb then return false,"Full" end
  self:wb(nb, B.pad(ent,self.d.sectorSize))
  local nExt=(dt.nExtents or 0)+1
  if nExt<=AX.MAX_IEXT then dt.extents[nExt]={nb,1}; dt.nExtents=nExt end
  dt.size=dt.size+AX.DIRENT_SZ
  dt.mtime=os.time and os.time() or 0
  self:wi(di,dt); self:_dirtyMeta(); return true
end

function AX._V:drem(di, nm)
  local dt=self:ri(di); if not dt then return false end
  local tBlocks=self:iblocks(dt)
  for _, bn in ipairs(tBlocks) do
    local sd=self:rb(bn)
    if sd then
      for i=0,self.L.dpb-1 do
        local o=i*AX.DIRENT_SZ; local e=rde(sd,o+1)
        if e and e.inode>0 and e.name==nm then
          sd=sd:sub(1,o)..B.pad("",AX.DIRENT_SZ)..sd:sub(o+AX.DIRENT_SZ+1)
          self:wb(bn,sd)
          dt.mtime=os.time and os.time() or 0
          self:wi(di,dt); self:_dirtyMeta(); return true
        end
      end
    end
  end
  return false
end

-- =============================================
-- PUBLIC API
-- =============================================

function AX._V:listDir(p)
  local n=self:resolve(p or "/")
  if not n then return nil,"Not found" end
  local t=self:ri(n)
  if not t or t.iType~=AX.DIR then return nil,"Not dir" end
  local tHash = self:_dirHash(t, n)
  local r={}
  for name, info in pairs(tHash) do
    if name~="." and name~=".." then
      local ci=self:ri(info.inode)
      r[#r+1]={
        name=name, inode=info.inode, iType=info.iType,
        size=ci and ci.size or 0, mode=ci and ci.mode or 0,
        inline=ci and bit32.band(ci.flags or 0,AX.F_INLINE)~=0,
      }
    end
  end
  return r
end

function AX._V:readFile(p)
  local n=self:resolve(p)
  if not n then return nil,"Not found" end
  local t=self:ri(n)
  if not t or t.iType~=AX.FILE then return nil,"Not file" end
  return self:readInodeData(t)
end

function AX._V:writeFile(p, data)
  data=data or ""
  local di,base,e=self:rpar(p)
  if not di then return false,e end
  if #base==0 or #base>AX.NAME_MAX then return false,"Bad name" end
  local now=os.time and os.time() or 0
  local pt=self:ri(di)
  local ex=self:dlookup(pt, base, di)
  local ino
  if ex then
    ino=ex
  else
    ino=self:ai()
    if not ino then return false,"No inodes" end
  end
  local t
  if ex then
    t=self:ri(ino)
    if not t then
      t={iType=AX.FILE,mode=0x1B6,uid=0,gid=0,size=0,
         ctime=now,mtime=now,links=1,flags=0,nExtents=0,extents={},indirect=0}
    end
  else
    t={iType=AX.FILE,mode=0x1B6,uid=0,gid=0,size=0,
       ctime=now,mtime=now,links=1,flags=0,nExtents=0,extents={},indirect=0}
  end
  local bOk,sErr=self:writeInodeData(ino, t, data)
  if not bOk then return false,sErr end
  if not ex then self:dadd(di, ino, AX.FILE, base) end
  -- Delayed flush: just mark dirty, don't write superblock
  self.dirty=true
  return true
end

function AX._V:removeFile(p)
  local di,base=self:rpar(p)
  if not di or #base==0 then return false end
  local pt=self:ri(di)
  local n=self:dlookup(pt, base, di)
  if not n then return false,"Not found" end
  local t=self:ri(n)
  if not t then return false end
  if t.iType==AX.DIR then return false,"Is dir" end
  self:freeIblocks(t)
  t.iType=AX.FREE; self:wi(n,t)
  self:fi2(n); self:drem(di,base)
  self.dirty=true
  return true
end

function AX._V:mkdir(p)
  local di,base,e=self:rpar(p)
  if not di then return false,e end
  if #base==0 or #base>AX.NAME_MAX then return false,"Bad name" end
  local pt=self:ri(di)
  if self:dlookup(pt, base, di) then return false,"Exists" end
  local ino=self:ai()
  if not ino then return false,"No inodes" end
  local bn=self:ab()
  if not bn then self:fi2(ino); return false,"Full" end
  local now=os.time and os.time() or 0
  local t={
    iType=AX.DIR,mode=0x1FF,uid=0,gid=0,
    size=AX.DIRENT_SZ*2,ctime=now,mtime=now,
    links=2,flags=AX.F_CHECKSUM,nExtents=1,
    extents={{bn,1}},indirect=0,
  }
  self:wi(ino,t)
  self:wb(bn, B.pad(pde(ino,AX.DIR,".")..pde(di,AX.DIR,".."),self.d.sectorSize))
  self:dadd(di, ino, AX.DIR, base)
  -- FIX: Re-read parent inode AFTER dadd (dadd already wrote correct
  -- size/mtime/extents to disk; we must not overwrite with stale pt).
  -- _dirtyMeta() inside dadd cleared all caches, so ri() reads from disk.
  local pt2=self:ri(di)
  if pt2 then
    pt2.links=pt2.links+1
    self:wi(di,pt2)
  end
  self.dirty=true
  return true
end

function AX._V:rmdir(p)
  local di,base=self:rpar(p)
  if not di or #base==0 then return false end
  local pt=self:ri(di)
  local n=self:dlookup(pt, base, di)
  if not n then return false,"Not found" end
  local t=self:ri(n)
  if not t or t.iType~=AX.DIR then return false,"Not dir" end
  local ents=self:listDir(p)
  if ents and #ents>0 then return false,"Not empty" end
  self:freeIblocks(t)
  t.iType=AX.FREE; self:wi(n,t)
  self:fi2(n); self:drem(di,base)
  pt.links=math.max(1,pt.links-1); self:wi(di,pt)
  self.dirty=true
  return true
end

function AX._V:stat(p)
  local n=self:resolve(p)
  if not n then return nil,"Not found" end
  local t=self:ri(n)
  if not t then return nil,"Read error" end
  t.inode=n
  t.isInline=bit32.band(t.flags or 0,AX.F_INLINE)~=0
  return t
end

function AX._V:rename(op, np)
  local od,ob=self:rpar(op); local nd,nb=self:rpar(np)
  if not od or not nd then return false end
  local ot=self:ri(od)
  local n=self:dlookup(ot, ob, od)
  if not n then return false end
  local t=self:ri(n)
  self:drem(od,ob); self:dadd(nd, n, t.iType, nb)
  self.dirty=true
  return true
end

-- =============================================
-- VOLUME INFO & HEALTH
-- =============================================

function AX._V:info()
  local s=self.su
  return {
    label=s.label, version=s.ver, sectorSize=s.ss,
    totalSectors=s.ts, maxInodes=s.mi, maxBlocks=s.mb,
    freeInodes=s.fi, freeBlocks=s.fb, dataStart=s.ds,
    generation=s.gen,
    usedKB=math.floor((s.mb-s.fb)*s.ss/1024),
    totalKB=math.floor(s.mb*s.ss/1024),
    inlineSupport=true, extentBased=true,
    -- v3 features
    checksums=self._bCk,
    cow=self._bCow,
    cowCopies=self._nCowCopies,
    checksumFails=self._nCkFails,
    totalReads=self._nReads + (s.nTotalReads or 0),
    totalWrites=self._nWrites + (s.nTotalWrites or 0),
  }
end

function AX._V:cacheStats()
  return ccStats(self._cc)
end

function AX._V:health()
  local tH = {issues = {}}
  -- Superblock CRC
  if self.su._crcValid == false then
    tH.issues[#tH.issues+1] = "Superblock CRC invalid"
  end
  -- Root inode
  local ri = self:ri(AX.ROOT_INO)
  if not ri or ri.iType ~= AX.DIR then
    tH.issues[#tH.issues+1] = "Root inode missing or corrupted"
  end
  -- Checksum failures
  if self._nCkFails > 0 then
    tH.issues[#tH.issues+1] = self._nCkFails .. " checksum failure(s)"
  end
  -- Free space consistency
  local nFreeCount = 0
  for bn = 0, self.su.mb - 1 do
    if not bbGet(self, bn) then nFreeCount = nFreeCount + 1 end
  end
  if nFreeCount ~= self.su.fb then
    tH.issues[#tH.issues+1] = string.format(
      "Free block count mismatch: superblock=%d actual=%d",
      self.su.fb, nFreeCount)
  end
  tH.ok = (#tH.issues == 0)
  tH.cache = ccStats(self._cc)
  return tH
end

-- Enable/disable features at runtime
function AX._V:setCow(b)
  self._bCow = b
  if b then self.su.flags = bit32.bor(self.su.flags, AX.FEAT_COW)
  else self.su.flags = bit32.band(self.su.flags, bit32.bnot(AX.FEAT_COW)) end
  self.dirty = true
end

function AX._V:setChecksums(b)
  if b and self.L.ckSec == 0 then
    return false, "Volume not formatted with checksums"
  end
  self._bCk = b
  return true
end

return AX