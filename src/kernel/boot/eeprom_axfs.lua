-- AxisOS AXFS Bootloader (no SecureBoot)
-- Boots kernel.lua from first AXFS partition on first unmanaged drive.
-- Falls back to managed filesystem if no drive found.

local c = component
local cp = computer

local gpu_addr = c.list("gpu")()
local scr_addr = c.list("screen")()
local drv_addr = c.list("drive")()
local fs_addr  = c.list("filesystem")()

local W, H = 80, 25
local g
if gpu_addr and scr_addr then
  g = c.proxy(gpu_addr)
  g.bind(scr_addr)
  W, H = g.getResolution()
  g.setBackground(0x000000); g.setForeground(0xFFFFFF)
  g.fill(1, 1, W, H, " ")
end

local y = 1
local function p(s, col)
  if not g then return end
  g.setForeground(col or 0xFFFFFF)
  g.set(2, y, tostring(s)); y = y + 1
end

local function halt(reason)
  p("", 0)
  p("BOOT FAILURE: " .. tostring(reason), 0xFF5555)
  p("System halted.", 0xAAAAAA)
  cp.beep(200, 1)
  while true do cp.pullSignal(math.huge) end
end

local function r16(s,o) return s:byte(o)*256+s:byte(o+1) end
local function r32(s,o) return s:byte(o)*16777216+s:byte(o+1)*65536+s:byte(o+2)*256+s:byte(o+3) end
local function rstr(s,o,n) local r=s:sub(o,o+n-1); local z=r:find("\0",1,true); return z and r:sub(1,z-1) or r end

p("AxisOS Boot", 0x00BCD4)

-- =============================================
-- TRY AXFS ON UNMANAGED DRIVE
-- =============================================

local boot_mode = nil
local drv, ss, pOff, pCnt
local oFs, readfile

if drv_addr then
  drv = c.proxy(drv_addr)
  ss = drv.getSectorSize()

  local h0 = drv.readSector(1)  -- sector 0
  if h0 and h0:sub(1,4) == "AXRD" then
    local nP = h0:byte(12)
    for i = 1, nP do
      local ps = drv.readSector(i + 1)
      if ps and ps:sub(1,4) == "AXPT" and rstr(ps,22,8) == "axfs" then
        pOff = r32(ps, 30); pCnt = r32(ps, 34)
        break
      end
    end
  end
end

if pOff then
  boot_mode = "axfs"
  p("AXFS at sector " .. pOff, 0x55FF55)

  local function prs(n) return drv.readSector(pOff + n + 1) end
  local sb = prs(0)
  if not sb or sb:sub(1,4) ~= "AXFS" then halt("Bad AXFS superblock") end
  local nDS = r16(sb, 20)
  local ips = math.floor(ss / 64)

  local function ri(n)
    local sec=3+math.floor(n/ips); local off=(n%ips)*64
    local sd=prs(sec); if not sd then return nil end; local o=off+1
    local t={iType=r16(sd,o),size=r32(sd,o+8),nBlk=r16(sd,o+22),dir={},ind=r16(sd,o+44)}
    for i=1,10 do t.dir[i]=r16(sd,o+24+(i-1)*2) end; return t
  end
  local function rb(n) return prs(nDS+n) end
  local function blks(t)
    local r={}
    for i=1,math.min(10,t.nBlk) do if t.dir[i] and t.dir[i]>0 then r[#r+1]=t.dir[i] end end
    if t.nBlk>10 and t.ind>0 then
      local si=rb(t.ind); if si then
        for i=1,math.floor(ss/2) do local p2=r16(si,(i-1)*2+1); if p2>0 then r[#r+1]=p2 end end
      end
    end; return r
  end
  local function dfind(di,nm)
    local dpb=math.floor(ss/32)
    for _,bn in ipairs(blks(di)) do
      local sd=rb(bn); if sd then
        for i=0,dpb-1 do local o=i*32+1; local ino=r16(sd,o)
          if ino>0 then local nl=sd:byte(o+3); if sd:sub(o+4,o+3+nl)==nm then return ino end end
        end
      end
    end
  end
  local function resolve(path)
    local cur=1
    for seg in path:gmatch("[^/]+") do
      local t=ri(cur); if not t or t.iType~=2 then return nil end
      cur=dfind(t,seg); if not cur then return nil end
    end; return cur
  end

  readfile = function(path)
    local n=resolve(path); if not n then return nil end
    local t=ri(n); if not t or t.iType~=1 then return nil end
    local ch={}; local rem=t.size
    for _,bn in ipairs(blks(t)) do
      local sd=rb(bn); if sd then ch[#ch+1]=sd:sub(1,math.min(rem,ss)); rem=rem-ss end
      if rem<=0 then break end
    end; return table.concat(ch)
  end

elseif fs_addr then
  boot_mode = "managed"
  oFs = c.proxy(fs_addr)
  p("Managed FS boot", 0xFFAA00)

  readfile = function(path)
    local h = oFs.open(path, "r")
    if not h then return nil end
    local ch = {}
    while true do local s = oFs.read(h, 8192); if not s then break end; ch[#ch+1] = s end
    oFs.close(h)
    return table.concat(ch)
  end

else
  halt("No bootable device")
end

-- =============================================
-- LOAD KERNEL
-- =============================================

p("Loading kernel...", 0xAAAAAA)
local kcode = readfile("/kernel.lua")
if not kcode or #kcode < 100 then halt("/kernel.lua not found or empty") end
p("Kernel: " .. #kcode .. " bytes", 0x55FF55)

-- Pass boot info
if boot_mode == "axfs" then
  _G.boot_fs_type = "axfs"
  _G.boot_drive_addr = drv_addr
  _G.boot_part_offset = pOff
  _G.boot_part_size = pCnt
  _G.boot_fs_address = drv_addr
else
  _G.boot_fs_type = "managed"
  _G.boot_fs_address = fs_addr
end
_G.boot_args = {}
_G.boot_security = nil  -- no security checks

cp.pullSignal(0.1)

local fn, err = load(kcode, "=kernel", "t", _G)
if not fn then halt("PARSE: " .. tostring(err)) end

local ok, err2 = xpcall(fn, debug.traceback)
if not ok then halt("PANIC: " .. tostring(err2)) end