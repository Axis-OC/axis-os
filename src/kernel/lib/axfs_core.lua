--
-- /lib/axfs_core.lua
-- AXFS: AxisOS Inode Filesystem
--
local B = require("bpack")
local AX = {}

AX.MAGIC = "AXFS"
AX.VERSION = 1
AX.MAX_INODES = 256
AX.INODE_SZ = 64
AX.DIRENT_SZ = 32
AX.NAME_MAX = 27
AX.NDIR = 10       -- direct block pointers
AX.ROOT = 1        -- root inode number

AX.FREE = 0; AX.FILE = 1; AX.DIR = 2; AX.LINK = 3

-- Layout: sect 0=super, 1=ibmp, 2=bbmp, 3..3+N-1=itable, 3+N..end=data
local function layout(nSS)
  local ips = math.floor(nSS / AX.INODE_SZ)
  local its = math.ceil(AX.MAX_INODES / ips)
  return { ips=ips, its=its, ds=3+its, dpb=math.floor(nSS/AX.DIRENT_SZ), ppb=math.floor(nSS/2) }
end

-- =============================================
-- DISK WRAPPERS
-- =============================================

function AX.wrapDrive(oProxy, nOff, nCnt)
  local ss = oProxy.getSectorSize()
  nOff = nOff or 0
  nCnt = nCnt or math.floor(oProxy.getCapacity() / ss)
  return {
    sectorSize = ss, sectorCount = nCnt,
    readSector  = function(n) return oProxy.readSector(nOff+n+1) end,
    writeSector = function(n,d)
      d = B.pad(d,ss); return oProxy.writeSector(nOff+n+1, d:sub(1,ss))
    end,
  }
end

function AX.wrapDevice(hDev, oFs, nOff, nCnt)
  local bI, tI = oFs.deviceControl(hDev, "info", {})
  if not bI then return nil, "No device info" end
  local ss = tI.sectorSize
  nOff = nOff or 0; nCnt = nCnt or tI.sectorCount
  return {
    sectorSize = ss, sectorCount = nCnt,
    readSector = function(n)
      local b, d = oFs.deviceControl(hDev, "read_sector", {nOff+n+1})
      return b and d or nil
    end,
    writeSector = function(n, d)
      d = B.pad(d, ss)
      return oFs.deviceControl(hDev, "write_sector", {nOff+n+1, d:sub(1,ss)})
    end,
  }
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
  local nw; if v then nw=o+m*(1-math.floor(o/m)%2) else nw=o-m*(math.floor(o/m)%2) end
  return s:sub(1,by-1)..string.char(nw)..s:sub(by+1)
end

local function bfree(s,mx)
  for i=0,mx-1 do if not bget(s,i) then return i end end
end

-- =============================================
-- INODE PACK/UNPACK
-- =============================================

local function pinode(t)
  local s = B.u16(t.iType or 0)..B.u16(t.mode or 0x1FF)
    ..B.u16(t.uid or 0)..B.u16(t.gid or 0)
    ..B.u32(t.size or 0)..B.u32(t.ctime or 0)..B.u32(t.mtime or 0)
    ..B.u16(t.links or 1)..B.u16(t.nBlk or 0)
  for i=1,AX.NDIR do s=s..B.u16(t.dir and t.dir[i] or 0) end
  s=s..B.u16(t.ind or 0)
  return B.pad(s, AX.INODE_SZ)
end

local function rinode(s,o)
  o=o or 1; if #s<o+AX.INODE_SZ-1 then return nil end
  local t={iType=B.r16(s,o), mode=B.r16(s,o+2), uid=B.r16(s,o+4), gid=B.r16(s,o+6),
    size=B.r32(s,o+8), ctime=B.r32(s,o+12), mtime=B.r32(s,o+16),
    links=B.r16(s,o+20), nBlk=B.r16(s,o+22), dir={}, ind=0}
  for i=1,AX.NDIR do t.dir[i]=B.r16(s,o+24+(i-1)*2) end
  t.ind=B.r16(s,o+44); return t
end

-- =============================================
-- DIRECTORY ENTRY
-- =============================================

local function pde(ino,tp,nm)
  nm=nm:sub(1,AX.NAME_MAX)
  return B.u16(ino)..string.char(tp,#nm)..B.str(nm,28)
end

local function rde(s,o)
  o=o or 1; if #s<o+AX.DIRENT_SZ-1 then return nil end
  return {inode=B.r16(s,o), iType=s:byte(o+2), name=s:sub(o+4, o+3+s:byte(o+3))}
end

-- =============================================
-- SUPERBLOCK
-- =============================================

local function psuper(t,ss)
  local s=AX.MAGIC..string.char(AX.VERSION)..B.u16(t.ss)..B.u32(t.ts)
    ..B.u16(t.mi)..B.u16(t.mb)..B.u16(t.fi)..B.u16(t.fb)..B.u16(t.ds)
    ..B.str(t.label,16)..B.u32(t.ct)..B.u32(t.mt)
  return B.pad(s,ss)
end

local function rsuper(s)
  if not s or #s<46 or s:sub(1,4)~=AX.MAGIC then return nil,"Not AXFS" end
  return {ver=s:byte(5), ss=B.r16(s,6), ts=B.r32(s,8), mi=B.r16(s,12), mb=B.r16(s,14),
    fi=B.r16(s,16), fb=B.r16(s,18), ds=B.r16(s,20), label=B.rstr(s,22,16),
    ct=B.r32(s,38), mt=B.r32(s,42)}
end

-- =============================================
-- FORMAT
-- =============================================

function AX.format(tD, sLabel)
  local ss=tD.sectorSize; local L=layout(ss)
  local mb=math.min(tD.sectorCount-L.ds, ss*8)
  if mb<1 then return nil,"Too small" end
  local now=os.time and os.time() or 0
  local su={ss=ss,ts=tD.sectorCount,mi=AX.MAX_INODES,mb=mb,fi=AX.MAX_INODES-2,
    fb=mb-1,ds=L.ds,label=sLabel or "AxisFS",ct=now,mt=now}
  tD.writeSector(0,psuper(su,ss))
  -- ibmp: mark 0,1 used
  local ib=B.pad("",ss); ib=bset(ib,0,true); ib=bset(ib,1,true)
  tD.writeSector(1,ib)
  -- bbmp: mark 0 used
  local bb=B.pad("",ss); bb=bset(bb,0,true)
  tD.writeSector(2,bb)
  -- clear itable
  local ez=B.pad("",ss)
  for i=0,L.its-1 do tD.writeSector(3+i,ez) end
  -- root inode (1)
  local ri={iType=AX.DIR,mode=0x1FF,uid=0,gid=0,size=AX.DIRENT_SZ*2,
    ctime=now,mtime=now,links=2,nBlk=1,dir={0},ind=0}
  local is=3+math.floor(1/L.ips); local io2=(1%L.ips)*AX.INODE_SZ
  local sd=tD.readSector(is) or ez
  sd=sd:sub(1,io2)..pinode(ri)..sd:sub(io2+AX.INODE_SZ+1)
  tD.writeSector(is,B.pad(sd,ss))
  -- root dir data (block 0)
  local dd=pde(1,AX.DIR,".")..pde(1,AX.DIR,"..")
  tD.writeSector(L.ds,B.pad(dd,ss))
  return true
end

-- =============================================
-- MOUNT → Volume object
-- =============================================

function AX.mount(tD)
  local su,e=rsuper(tD.readSector(0))
  if not su then return nil,e end
  local L=layout(tD.sectorSize)
  local v={d=tD,su=su,L=L,ib=tD.readSector(1),bb=tD.readSector(2),dirty=false}
  setmetatable(v,{__index=AX._V})
  return v
end

AX._V={}

function AX._V:flush()
  if not self.dirty then return end
  self.d.writeSector(1,self.ib); self.d.writeSector(2,self.bb)
  self.su.mt=os.time and os.time() or 0
  self.d.writeSector(0,psuper(self.su,self.d.sectorSize))
  self.dirty=false
end

function AX._V:unmount() self:flush() end

function AX._V:ri(n)
  local s=3+math.floor(n/self.L.ips); local o=(n%self.L.ips)*AX.INODE_SZ
  local sd=self.d.readSector(s); if not sd then return nil end
  return rinode(sd,o+1)
end

function AX._V:wi(n,t)
  local ss=self.d.sectorSize; local s=3+math.floor(n/self.L.ips)
  local o=(n%self.L.ips)*AX.INODE_SZ
  local sd=self.d.readSector(s) or B.pad("",ss)
  sd=sd:sub(1,o)..pinode(t)..sd:sub(o+AX.INODE_SZ+1)
  self.d.writeSector(s,B.pad(sd,ss))
end

function AX._V:ai()
  local n=bfree(self.ib,self.su.mi); if not n then return nil end
  self.ib=bset(self.ib,n,true); self.su.fi=self.su.fi-1; self.dirty=true; return n
end

function AX._V:fi2(n)
  self.ib=bset(self.ib,n,false); self.su.fi=self.su.fi+1; self.dirty=true
end

function AX._V:ab()
  local n=bfree(self.bb,self.su.mb); if not n then return nil end
  self.bb=bset(self.bb,n,true); self.su.fb=self.su.fb-1; self.dirty=true; return n
end

function AX._V:fb(n)
  if not n or n==0 then return end
  self.bb=bset(self.bb,n,false); self.su.fb=self.su.fb+1; self.dirty=true
end

function AX._V:b2s(n) return self.su.ds+n end
function AX._V:rb(n) return self.d.readSector(self:b2s(n)) end
function AX._V:wb(n,d) self.d.writeSector(self:b2s(n),B.pad(d,self.d.sectorSize)) end

function AX._V:blks(t)
  local r={}
  for i=1,math.min(AX.NDIR,t.nBlk) do
    if t.dir[i] and t.dir[i]>0 then r[#r+1]=t.dir[i] end
  end
  if t.nBlk>AX.NDIR and t.ind>0 then
    local si=self:rb(t.ind)
    if si then for i=1,self.L.ppb do
      local p=B.r16(si,(i-1)*2+1); if p>0 then r[#r+1]=p end
    end end
  end
  return r
end

function AX._V:setblk(t,idx,bn)
  if idx<AX.NDIR then t.dir[idx+1]=bn
  else
    if t.ind==0 then
      local ib=self:ab(); if not ib then return false end
      t.ind=ib; self:wb(ib,B.pad("",self.d.sectorSize))
    end
    local sl=idx-AX.NDIR; local si=self:rb(t.ind)
    si=si:sub(1,sl*2)..B.u16(bn)..si:sub(sl*2+3)
    self:wb(t.ind,si)
  end
  t.nBlk=math.max(t.nBlk,idx+1); return true
end

function AX._V:freeblks(t)
  for _,b in ipairs(self:blks(t)) do self:fb(b) end
  if t.ind>0 then self:fb(t.ind) end
end

-- =============================================
-- PATH
-- =============================================

function AX._V:split(p)
  local r={}; for s in p:gmatch("[^/]+") do
    if s==".." then if #r>0 then table.remove(r) end
    elseif s~="." and s~="" then r[#r+1]=s end
  end; return r
end

function AX._V:dlookup(di,nm)
  local tb=self:blks(di)
  for _,bn in ipairs(tb) do
    local sd=self:rb(bn); if sd then
      for i=0,self.L.dpb-1 do
        local e=rde(sd,i*AX.DIRENT_SZ+1)
        if e and e.inode>0 and e.name==nm then return e.inode,e end
      end
    end
  end
end

function AX._V:resolve(p)
  local parts=self:split(p); local c=AX.ROOT
  for _,nm in ipairs(parts) do
    local t=self:ri(c)
    if not t or t.iType~=AX.DIR then return nil,"Not a dir" end
    local ch=self:dlookup(t,nm)
    if not ch then return nil,"Not found: "..nm end; c=ch
  end; return c
end

function AX._V:rpar(p)
  local parts=self:split(p)
  if #parts==0 then return AX.ROOT,"" end
  local base=table.remove(parts); local c=AX.ROOT
  for _,nm in ipairs(parts) do
    local t=self:ri(c)
    if not t or t.iType~=AX.DIR then return nil,nil,"Bad path" end
    local ch=self:dlookup(t,nm)
    if not ch then return nil,nil,"Not found: "..nm end; c=ch
  end; return c,base
end

-- =============================================
-- DIRECTORY OPS
-- =============================================

function AX._V:dadd(di,ci,ct,nm)
  local dt=self:ri(di); if not dt then return false end
  local ent=pde(ci,ct,nm); local dpb=self.L.dpb
  for _,bn in ipairs(self:blks(dt)) do
    local sd=self:rb(bn); if sd then
      for i=0,dpb-1 do local o=i*AX.DIRENT_SZ
        local e=rde(sd,o+1)
        if not e or e.inode==0 then
          sd=sd:sub(1,o)..ent..sd:sub(o+AX.DIRENT_SZ+1)
          self:wb(bn,sd)
          dt.mtime=os.time and os.time() or 0; self:wi(di,dt); return true
        end
      end
    end
  end
  local nb=self:ab(); if not nb then return false,"Full" end
  self:wb(nb,B.pad(ent,self.d.sectorSize))
  self:setblk(dt,dt.nBlk,nb)
  dt.mtime=os.time and os.time() or 0; self:wi(di,dt); return true
end

function AX._V:drem(di,nm)
  local dt=self:ri(di); if not dt then return false end
  for _,bn in ipairs(self:blks(dt)) do
    local sd=self:rb(bn); if sd then
      for i=0,self.L.dpb-1 do local o=i*AX.DIRENT_SZ
        local e=rde(sd,o+1)
        if e and e.inode>0 and e.name==nm then
          sd=sd:sub(1,o)..B.pad("",AX.DIRENT_SZ)..sd:sub(o+AX.DIRENT_SZ+1)
          self:wb(bn,sd); dt.mtime=os.time and os.time() or 0
          self:wi(di,dt); return true
        end
      end
    end
  end; return false
end

-- =============================================
-- PUBLIC API
-- =============================================

function AX._V:listDir(p)
  local n=self:resolve(p or "/"); if not n then return nil,"Not found" end
  local t=self:ri(n); if not t or t.iType~=AX.DIR then return nil,"Not dir" end
  local r={}
  for _,bn in ipairs(self:blks(t)) do
    local sd=self:rb(bn); if sd then
      for i=0,self.L.dpb-1 do
        local e=rde(sd,i*AX.DIRENT_SZ+1)
        if e and e.inode>0 and e.name~="." and e.name~=".." then
          local ci=self:ri(e.inode)
          r[#r+1]={name=e.name,inode=e.inode,iType=e.iType,
            size=ci and ci.size or 0, mode=ci and ci.mode or 0}
        end
      end
    end
  end; return r
end

function AX._V:readFile(p)
  local n=self:resolve(p); if not n then return nil,"Not found" end
  local t=self:ri(n); if not t or t.iType~=AX.FILE then return nil,"Not file" end
  local ch={}; local rem=t.size
  for _,bn in ipairs(self:blks(t)) do
    local sd=self:rb(bn); if sd then
      ch[#ch+1]=sd:sub(1,math.min(rem,self.d.sectorSize)); rem=rem-self.d.sectorSize
    end; if rem<=0 then break end
  end; return table.concat(ch)
end

function AX._V:writeFile(p,data)
  data=data or ""; local di,base,e=self:rpar(p)
  if not di then return false,e end
  if #base==0 or #base>AX.NAME_MAX then return false,"Bad name" end
  local now=os.time and os.time() or 0; local ss=self.d.sectorSize
  local need=math.max(1,math.ceil(#data/ss))
  local pt=self:ri(di); local ex=self:dlookup(pt,base); local ino
  if ex then ino=ex; local old=self:ri(ino); if old then self:freeblks(old) end
  else ino=self:ai(); if not ino then return false,"No inodes" end end
  local t={iType=AX.FILE,mode=0x1B6,uid=0,gid=0,size=#data,
    ctime=now,mtime=now,links=1,nBlk=0,dir={},ind=0}
  local off=1
  for i=0,need-1 do
    local bn=self:ab(); if not bn then self:flush(); return false,"Full" end
    self:setblk(t,i,bn); self:wb(bn,data:sub(off,off+ss-1)); off=off+ss
  end
  self:wi(ino,t)
  if not ex then self:dadd(di,ino,AX.FILE,base) end
  self:flush(); return true
end

function AX._V:removeFile(p)
  local di,base=self:rpar(p); if not di or #base==0 then return false end
  local pt=self:ri(di); local n=self:dlookup(pt,base); if not n then return false,"Not found" end
  local t=self:ri(n); if not t then return false end
  if t.iType==AX.DIR then return false,"Is dir" end
  self:freeblks(t); t.iType=AX.FREE; self:wi(n,t)
  self:fi2(n); self:drem(di,base); self:flush(); return true
end

function AX._V:mkdir(p)
  local di,base,e=self:rpar(p); if not di then return false,e end
  if #base==0 or #base>AX.NAME_MAX then return false,"Bad name" end
  local pt=self:ri(di); if self:dlookup(pt,base) then return false,"Exists" end
  local ino=self:ai(); if not ino then return false,"No inodes" end
  local bn=self:ab(); if not bn then self:fi2(ino); return false,"Full" end
  local now=os.time and os.time() or 0
  local t={iType=AX.DIR,mode=0x1FF,uid=0,gid=0,size=AX.DIRENT_SZ*2,
    ctime=now,mtime=now,links=2,nBlk=1,dir={bn},ind=0}
  self:wi(ino,t)
  self:wb(bn,B.pad(pde(ino,AX.DIR,"..")..pde(di,AX.DIR,".."),self.d.sectorSize))
  -- Fix: . should point to self, .. to parent
  self:wb(bn,B.pad(pde(ino,AX.DIR,".")..pde(di,AX.DIR,".."),self.d.sectorSize))
  self:dadd(di,ino,AX.DIR,base)
  pt.links=pt.links+1; self:wi(di,pt); self:flush(); return true
end

function AX._V:rmdir(p)
  local di,base=self:rpar(p); if not di or #base==0 then return false end
  local pt=self:ri(di); local n=self:dlookup(pt,base); if not n then return false,"Not found" end
  local t=self:ri(n); if not t or t.iType~=AX.DIR then return false,"Not dir" end
  local ents=self:listDir(p); if ents and #ents>0 then return false,"Not empty" end
  self:freeblks(t); t.iType=AX.FREE; self:wi(n,t)
  self:fi2(n); self:drem(di,base)
  pt.links=math.max(1,pt.links-1); self:wi(di,pt); self:flush(); return true
end

function AX._V:stat(p)
  local n=self:resolve(p); if not n then return nil,"Not found" end
  local t=self:ri(n); if not t then return nil,"Read error" end
  t.inode=n; return t
end

function AX._V:rename(op,np)
  local od,ob=self:rpar(op); local nd,nb=self:rpar(np)
  if not od or not nd then return false end
  local ot=self:ri(od); local n=self:dlookup(ot,ob); if not n then return false end
  local t=self:ri(n); self:drem(od,ob); self:dadd(nd,n,t.iType,nb)
  self:flush(); return true
end

function AX._V:info()
  local s=self.su
  return {label=s.label,version=s.ver,sectorSize=s.ss,totalSectors=s.ts,
    maxInodes=s.mi,maxBlocks=s.mb,freeInodes=s.fi,freeBlocks=s.fb,
    dataStart=s.ds,usedKB=math.floor((s.mb-s.fb)*s.ss/1024),
    totalKB=math.floor(s.mb*s.ss/1024)}
end

return AX