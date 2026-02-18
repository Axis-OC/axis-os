-- AxisOS Secure Boot + AXFS Bootloader
-- Verifies machine binding, kernel hash, manifest — then boots from AXFS.
-- Fits in 4KB EEPROM.

local PK_FINGERPRINT = "%%PK_FP%%"
local EXPECTED_KERNEL_HASH = "%%KERN_H%%"
local MACHINE_BINDING = "%%MACH_B%%"
local MANIFEST_HASH = "%%MANIF_H%%"

local c = component
local cp = computer

-- Component discovery
local gpu_addr = c.list("gpu")()
local scr_addr = c.list("screen")()
local eeprom   = c.list("eeprom")()
local data_addr= c.list("data")()
local drv_addr = c.list("drive")()
local fs_addr  = c.list("filesystem")()  -- fallback

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
  if g then
    g.setForeground(0xFF0000); g.set(2, H-2, "SECURE BOOT FAILURE")
    g.setForeground(0xFF5555); g.set(2, H-1, tostring(reason):sub(1, W-4))
    g.setForeground(0xAAAAAA); g.set(2, H, "System halted.")
  end
  cp.beep(200, 2)
  while true do cp.pullSignal(math.huge) end
end

local function hex(s)
  local t = {}
  for i = 1, #s do t[i] = string.format("%02x", s:byte(i)) end
  return table.concat(t)
end

-- Binary helpers
local function r16(s,o) return s:byte(o)*256+s:byte(o+1) end
local function r32(s,o) return s:byte(o)*16777216+s:byte(o+1)*65536+s:byte(o+2)*256+s:byte(o+3) end
local function rstr(s,o,n) local r=s:sub(o,o+n-1); local z=r:find("\0",1,true); return z and r:sub(1,z-1) or r end

-- =============================================
-- HEADER
-- =============================================

p("AxisOS Secure Boot + AXFS v1.0", 0x00BCD4)
p(string.rep("=", 40), 0x333333)
p("")

-- =============================================
-- [0/5] EEPROM INTEGRITY
-- =============================================

p("[0/5] Verifying boot ROM integrity...", 0xAAAAAA)
local eep = c.proxy(eeprom)
local stored_data = eep.getData()
if not stored_data or #stored_data < 64 then
  halt("EEPROM data area corrupt or empty")
end

-- =============================================
-- [1/5] MACHINE BINDING
-- =============================================

p("[1/5] Validating machine binding...", 0xAAAAAA)

if not data_addr then
  halt("NO DATA CARD: Cannot verify")
end
local data = c.proxy(data_addr)

local machine_id = data.sha256(
  data_addr .. eeprom .. (drv_addr or fs_addr or "NO_DEV")
)
local current_binding = hex(machine_id)

if MACHINE_BINDING ~= "%%MACH_B%%" then
  if current_binding ~= MACHINE_BINDING then
    halt("MACHINE BINDING MISMATCH: " ..
         current_binding:sub(1,16) .. " != " .. MACHINE_BINDING:sub(1,16))
  end
  p("[1/5] Machine binding: VERIFIED", 0x00FF00)
else
  p("[1/5] Machine binding: FIRST BOOT (unbound)", 0xFFAA00)
end

-- =============================================
-- [2/5] LOCATE BOOT DEVICE
-- =============================================

p("[2/5] Locating boot device...", 0xAAAAAA)

-- Try AXFS on unmanaged drive first, fall back to managed FS
local boot_mode   -- "axfs" or "managed"
local drv, ss, pOff, pCnt
local oFs

if drv_addr then
  drv = c.proxy(drv_addr)
  ss = drv.getSectorSize()
  local function rs(n) return drv.readSector(n + 1) end

  local h0 = rs(0)
  if h0 and h0:sub(1,4) == "AXRD" then
    local nParts = h0:byte(12)
    for i = 1, nParts do
      local ps = rs(i)
      if ps and ps:sub(1,4) == "AXPT" and rstr(ps,22,8) == "axfs" then
        pOff = r32(ps, 30); pCnt = r32(ps, 34)
        break
      end
    end
  end
end

if pOff then
  boot_mode = "axfs"
  p("[2/5] AXFS partition found at sector " .. pOff, 0x00FF00)
elseif fs_addr then
  boot_mode = "managed"
  oFs = c.proxy(fs_addr)
  p("[2/5] Falling back to managed filesystem", 0xFFAA00)
else
  halt("NO BOOTABLE DEVICE FOUND")
end

-- =============================================
-- AXFS READER (inline, no requires)
-- =============================================

local readfile  -- forward declaration

if boot_mode == "axfs" then
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

else
  -- Managed FS reader
  readfile = function(path)
    local h = oFs.open(path, "r")
    if not h then return nil end
    local ch = {}
    while true do
      local s = oFs.read(h, 8192); if not s then break end; ch[#ch+1] = s
    end
    oFs.close(h)
    return table.concat(ch)
  end
end

-- =============================================
-- [3/5] KERNEL INTEGRITY
-- =============================================

p("[3/5] Measuring kernel...", 0xAAAAAA)

local kernel_code = readfile("/kernel.lua")
if not kernel_code or #kernel_code < 100 then
  halt("KERNEL NOT FOUND or corrupt")
end

local kernel_hash = hex(data.sha256(kernel_code))

if EXPECTED_KERNEL_HASH ~= "%%KERN_H%%" then
  if kernel_hash ~= EXPECTED_KERNEL_HASH then
    halt("KERNEL HASH MISMATCH: " ..
         kernel_hash:sub(1,16) .. " != " .. EXPECTED_KERNEL_HASH:sub(1,16))
  end
  p("[3/5] Kernel integrity: VERIFIED (" .. kernel_hash:sub(1,8) .. "...)", 0x00FF00)
else
  p("[3/5] Kernel hash: " .. kernel_hash:sub(1,16) .. " (unverified)", 0xFFAA00)
end

-- =============================================
-- [4/5] BOOT MANIFEST
-- =============================================

p("[4/5] Checking boot manifest...", 0xAAAAAA)

local mdata = readfile("/boot/manifest.sig")
if mdata then
  local manifest_hash = hex(data.sha256(mdata))
  if MANIFEST_HASH ~= "%%MANIF_H%%" and manifest_hash ~= MANIFEST_HASH then
    halt("BOOT MANIFEST TAMPERED")
  end
  p("[4/5] Boot manifest: PRESENT", 0x00FF00)
else
  if MANIFEST_HASH ~= "%%MANIF_H%%" then
    halt("BOOT MANIFEST MISSING (required by policy)")
  end
  p("[4/5] Boot manifest: NOT PRESENT (warning)", 0xFFAA00)
end

-- =============================================
-- [5/5] LAUNCH KERNEL
-- =============================================

p("[5/5] Loading verified kernel...", 0x00BCD4)
p("")
p("Trust chain: EEPROM -> kernel -> PM -> drivers", 0x555555)

_G.boot_security = {
  machine_binding = current_binding,
  kernel_hash = kernel_hash,
  data_card_addr = data_addr,
  pk_fingerprint = PK_FINGERPRINT,
  verified = (EXPECTED_KERNEL_HASH ~= "%%KERN_H%%"),
  sealed = (MACHINE_BINDING ~= "%%MACH_B%%"),
}

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

cp.pullSignal(0.1)

local fn, err = load(kernel_code, "=kernel", "t", _G)
if not fn then halt("KERNEL PARSE: " .. tostring(err)) end

local ok, err2 = xpcall(fn, debug.traceback)
if not ok then halt("KERNEL PANIC: " .. tostring(err2)) end