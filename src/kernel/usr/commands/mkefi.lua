-- /usr/commands/mkefi.lua
-- AxisOS EFI Partition Manager
-- Usage: mkefi <init|setup|sign|info|enable|disable> [drive_addr]
-- Requires: root (ring 0-1)

local args = env.ARGS or {}
local cmd = args[1]
local sha -- loaded on demand

local function usage()
  print("mkefi - AxisOS EFI Partition Manager")
  print("Usage: mkefi <command> [drive_addr]")
  print("")
  print("Commands:")
  print("  init      Create RDB + EFI + format AXFS (DESTRUCTIVE)")
  print("  setup     Populate EFI partition (after OS install)")
  print("  sign      Re-sign kernel HMAC-SHA256")
  print("  info      Show EFI partition status")
  print("  enable    Enable SecureBoot")
  print("  disable   Disable SecureBoot")
  print("  verify    Verify current kernel signature")
end

if not cmd or cmd=="help" then usage(); return end

-- ── Load SHA-256 ──
local ok, shaLib = pcall(require, "sha256")
if ok then sha = shaLib
else
  -- Fallback: load directly
  local fh = io.open("/lib/sha256.lua","r")
  if fh then
    local code = fh:read("*a"); fh:close()
    local env = setmetatable({bit32=bit32,string=string,math=math,
      table=table,tostring=tostring},{__index=_G})
    sha = load(code,"=sha256","t",env)()
  end
end
if not sha then print("Error: Cannot load SHA-256 library"); return end

-- ── Find drive ──
local driveAddr = args[2]
if not driveAddr then
  local bOk, tList = syscall("disk_list_drives", "drive")
  if bOk and tList then
    for a in pairs(tList) do driveAddr = a; break end
  end
end
if not driveAddr then print("Error: No drive found"); return end

local drv = syscall("disk_list_drives", driveAddr)
local ss = drv.getSectorSize()
local cap = drv.getCapacity()
local totalSec = math.floor(cap / ss)

-- ── Helpers ──
local function r16(s,o) return s:byte(o)*256+s:byte(o+1) end
local function r32(s,o)
  return s:byte(o)*0x1000000+s:byte(o+1)*0x10000
        +s:byte(o+2)*0x100+s:byte(o+3)
end
local function w16(n)
  return string.char(math.floor(n/256)%256, n%256)
end
local function w32(n)
  return string.char(math.floor(n/0x1000000)%256,
    math.floor(n/0x10000)%256, math.floor(n/0x100)%256, n%256)
end
local function pad(s,n) return (#s>=n) and s:sub(1,n) or s..string.rep("\0",n-#s) end

local function rs(n) return drv.readSector(n+1) end
local function ws(n,d) return drv.writeSector(n+1, pad(d,ss)) end

-- CRC32
local ct={}
for i=0,255 do local c=i for _=1,8 do
  if c%2==1 then c=bit32.bxor(bit32.rshift(c,1),0xEDB88320)
  else c=bit32.rshift(c,1) end
end ct[i]=c end
local function crc32(s) local c=0xFFFFFFFF for i=1,#s do
  c=bit32.bxor(bit32.rshift(c,8),ct[bit32.band(bit32.bxor(c,s:byte(i)),0xFF)])
end return bit32.bxor(c,0xFFFFFFFF) end

-- ── RDB helpers ──
local function readRDB()
  local s=rs(0)
  if not s or s:sub(1,4)~="ARDB" then return nil end
  local parts={}
  for i=0,s:byte(6)-1 do
    local o=9+i*32
    parts[#parts+1]={
      type=s:sub(o,o+7):gsub("\0",""),
      offset=r32(s,o+8), size=r32(s,o+12),
      flags=r16(s,o+16), label=s:sub(o+18,o+31):gsub("\0",""),
    }
  end
  return parts
end

local function writeRDB(parts)
  local s="ARDB"..string.char(1,#parts,0,0)
  for _,pt in ipairs(parts) do
    s=s..pad(pt.type,8)..w32(pt.offset)..w32(pt.size)
     ..w16(pt.flags or 0)..pad(pt.label or "",14)
  end
  ws(0, pad(s,ss))
end

local function findPart(parts,ptype)
  if not parts then return nil end
  for i,pt in ipairs(parts) do
    if pt.type==ptype then return pt,i end
  end
end

-- =========================================================
-- INIT: Create RDB + EFI + format AXFS
-- =========================================================
if cmd=="init" then
  print("=== AxisOS EFI Init ===")
  print("Drive: "..driveAddr:sub(1,8).."...")
  print("Size:  "..totalSec.." sectors ("..math.floor(cap/1024).." KB)")
  print("")
  print("WARNING: ALL DATA WILL BE DESTROYED!")
  io.write("Type 'YES' to confirm: ")
  local confirm = io.read()
  if confirm~="YES" then print("Aborted."); return end

  local EFI_SEC = 32
  local efiOff = 1
  local axOff = efiOff + EFI_SEC
  local axSz = totalSec - axOff

  print("Creating RDB...")
  writeRDB({
    {type="AXEFI",offset=efiOff,size=EFI_SEC,flags=3,label="EFI"},
    {type="AXFS",offset=axOff,size=axSz,flags=1,label="AxisOS"},
  })

  -- Zero-fill EFI partition
  for i=0,EFI_SEC-1 do ws(efiOff+i, "") end

  -- Format AXFS partition
  print("Formatting AXFS ("..axSz.." sectors)...")
  local bOk, AX = pcall(require, "axfs_core")
  if bOk and AX then
    local disk = AX.wrapDrive(drv, axOff, axSz)
    local ok2, err = AX.format(disk, "AxisOS")
    if ok2 then print("AXFS formatted OK")
    else print("AXFS format failed: "..tostring(err)); return end
  else
    print("Warning: axfs_core not available, AXFS not formatted")
    print("Format manually after installing libraries")
  end

  print("")
  print("Done! Next steps:")
  print("  1. Install OS files to AXFS partition")
  print("  2. Run: mkefi setup")
  print("  3. Flash SecureBoot EEPROM")

-- =========================================================
-- SETUP: Populate EFI partition with bootloader + keys
-- =========================================================
elseif cmd=="setup" then
  print("=== AxisOS EFI Setup ===")
  local parts = readRDB()
  if not parts then print("No RDB. Run 'mkefi init' first."); return end

  local efi = findPart(parts, "AXEFI")
  if not efi then print("No AXEFI partition. Run 'mkefi init' first."); return end

  -- Read stage 3 bootloader source
  print("Reading /lib/efi_stage3.lua...")
  local fh = io.open("/lib/efi_stage3.lua", "r")
  if not fh then print("Error: /lib/efi_stage3.lua not found"); return end
  local bootCode = fh:read("*a"); fh:close()
  if #bootCode==0 then print("Error: empty bootloader"); return end
  print("  Boot code: "..#bootCode.." bytes")

  -- Read kernel for signing
  print("Reading /kernel.lua...")
  local kfh = io.open("/kernel.lua", "r")
  if not kfh then print("Error: /kernel.lua not found"); return end
  local kernData = kfh:read("*a"); kfh:close()
  print("  Kernel: "..#kernData.." bytes")

  -- Generate HMAC key
  print("Generating HMAC key...")
  local seed = computer.address()
    .. tostring(os.time()) .. tostring(computer.uptime())
  for i=1,16 do seed = seed..tostring(math.random(0,0x7FFFFFFF)) end
  local hmacKey = sha.digest(seed)

  -- Machine binding
  local binding = sha.digest(computer.address())

  -- Kernel signature
  local kernSig = sha.hmac(hmacKey, kernData)
  print("  Kernel HMAC: "..sha.hex(kernSig):sub(1,16).."...")

  -- Boot code CRC
  local bcCrc = crc32(bootCode)
  local bcStartSec = 3  -- relative to EFI partition
  local bcSecCount = math.ceil(#bootCode / ss)

  if bcStartSec + bcSecCount > efi.size then
    print("Error: boot code too large for EFI partition")
    return
  end

  -- ── Write EFI header (sector 0 of EFI partition) ──
  print("Writing EFI header...")
  local ehData = "AEFI" .. string.char(1)     -- [1-5] magic+ver
    .. w16(#bootCode)                           -- [6-7] boot code size
    .. w32(bcCrc)                               -- [8-11] boot code CRC32
    .. w16(1) .. w16(2)                         -- [12-15] key block sec+count
    .. w16(bcStartSec) .. w16(bcSecCount)       -- [16-19] boot code sec+count
    .. string.char(1)                           -- [20] SecureBoot ON
    .. binding                                  -- [21-52] machine binding
  ehData = ehData .. w32(crc32(ehData))         -- [53-56] header CRC
  ws(efi.offset, pad(ehData, ss))

  -- ── Write key block (sector 1 of EFI partition) ──
  print("Writing key block...")
  local kbData = "AKEY" .. string.char(1, 32)  -- [1-6] magic+type+len
    .. hmacKey                                   -- [7-38] HMAC key
    .. kernSig                                   -- [39-70] kernel signature
    .. sha.hmac(hmacKey, bootCode)              -- [71-102] boot code sig
  kbData = kbData .. w32(crc32(kbData))         -- [103-106] CRC
  ws(efi.offset + 1, pad(kbData, ss))
  ws(efi.offset + 2, pad("", ss))  -- reserved

  -- ── Write boot code (sectors 3+ of EFI partition) ──
  print("Writing boot code ("..bcSecCount.." sectors)...")
  for i=0, bcSecCount-1 do
    local chunk = bootCode:sub(i*ss+1, (i+1)*ss)
    ws(efi.offset + bcStartSec + i, pad(chunk, ss))
  end

  print("")
  print("EFI setup complete!")
  print("  SecureBoot: ENABLED")
  print("  Machine:    "..sha.hex(binding):sub(1,16).."...")
  print("  Kernel sig: "..sha.hex(kernSig):sub(1,16).."...")
  print("")
  print("Flash the SecureBoot EEPROM and reboot.")

-- =========================================================
-- SIGN: Re-sign kernel (after kernel update)
-- =========================================================
elseif cmd=="sign" then
  print("=== Re-sign Kernel ===")
  local parts = readRDB()
  if not parts then print("No RDB."); return end
  local efi = findPart(parts,"AXEFI")
  if not efi then print("No AXEFI partition."); return end

  -- Read existing key
  local kb = rs(efi.offset + 1)
  if not kb or kb:sub(1,4)~="AKEY" then print("Invalid key block."); return end
  local hmacKey = kb:sub(7, 38)

  -- Read kernel
  print("Reading /kernel.lua...")
  local fh = io.open("/kernel.lua","r")
  if not fh then print("Cannot read /kernel.lua"); return end
  local kern = fh:read("*a"); fh:close()
  print("  Size: "..#kern.." bytes")

  -- Compute new signature
  local sig = sha.hmac(hmacKey, kern)
  print("  New HMAC: "..sha.hex(sig):sub(1,16).."...")

  -- Update key block: replace bytes 39-70
  local newKb = kb:sub(1,38) .. sig .. kb:sub(71,102)
  newKb = newKb .. w32(crc32(newKb))
  ws(efi.offset + 1, pad(newKb, ss))

  print("Kernel re-signed successfully!")

-- =========================================================
-- INFO
-- =========================================================
elseif cmd=="info" then
  print("=== EFI Partition Info ===")
  local parts = readRDB()
  if not parts then print("No RDB on this drive."); return end

  print("RDB partitions:")
  for i,pt in ipairs(parts) do
    print(string.format("  %d. [%s] offset=%d size=%d label=%s flags=%04x",
      i, pt.type, pt.offset, pt.size, pt.label, pt.flags))
  end

  local efi = findPart(parts,"AXEFI")
  if not efi then print("\nNo AXEFI partition."); return end

  local eh = rs(efi.offset)
  if not eh or eh:sub(1,4)~="AEFI" then print("\nInvalid EFI header."); return end

  print("\nEFI Header:")
  print("  Version:    "..eh:byte(5))
  print("  Boot code:  "..r16(eh,6).." bytes ("..r16(eh,18).." sectors)")
  print("  SecureBoot: "..(eh:byte(20)==1 and "ENABLED" or "DISABLED"))
  print("  Binding:    "..sha.hex(eh:sub(21,52)):sub(1,32).."...")

  local hdrCrc = r32(eh,53)
  local hdrOk = crc32(eh:sub(1,52))==hdrCrc
  print("  Header CRC: "..(hdrOk and "OK" or "FAIL"))

  local kb = rs(efi.offset+1)
  if kb and kb:sub(1,4)=="AKEY" then
    print("\nKey Block:")
    print("  Type:       HMAC-SHA256")
    print("  Key:        "..sha.hex(kb:sub(7,38)):sub(1,32).."...")
    local sig = kb:sub(39,70)
    local allZ = true
    for i=1,32 do if sig:byte(i)~=0 then allZ=false break end end
    print("  Kernel sig: "..(allZ and "(not signed)" or sha.hex(sig):sub(1,32).."..."))
    local kbCrc = r32(kb,103)
    if kbCrc~=0 then
      print("  KB CRC:     "..(crc32(kb:sub(1,102))==kbCrc and "OK" or "FAIL"))
    end
  end

  -- Check current machine binding
  local actual = sha.digest(computer.address())
  local stored = eh:sub(21,52)
  print("\nMachine check: "..(sha.constEq(actual,stored) and "MATCH" or "MISMATCH (drive moved!)"))

-- =========================================================
-- VERIFY: Check current kernel against stored signature
-- =========================================================
elseif cmd=="verify" then
  print("=== Verify Kernel Signature ===")
  local parts = readRDB()
  local efi = findPart(parts or {},"AXEFI")
  if not efi then print("No EFI partition."); return end

  local kb = rs(efi.offset+1)
  if not kb or kb:sub(1,4)~="AKEY" then print("Invalid key block."); return end
  local hmacKey = kb:sub(7,38)
  local storedSig = kb:sub(39,70)

  local fh = io.open("/kernel.lua","r")
  if not fh then print("Cannot read /kernel.lua"); return end
  local kern = fh:read("*a"); fh:close()

  local actualSig = sha.hmac(hmacKey, kern)
  print("Stored:  "..sha.hex(storedSig))
  print("Actual:  "..sha.hex(actualSig))
  print("Result:  "..(sha.constEq(storedSig, actualSig) and "VALID" or "INVALID"))

-- =========================================================
-- ENABLE / DISABLE SecureBoot
-- =========================================================
elseif cmd=="enable" or cmd=="disable" then
  local parts = readRDB()
  local efi = findPart(parts or {},"AXEFI")
  if not efi then print("No EFI partition."); return end

  local eh = rs(efi.offset)
  if not eh or eh:sub(1,4)~="AEFI" then print("Invalid EFI header."); return end

  local newFlag = (cmd=="enable") and 1 or 0
  local newEh = eh:sub(1,19)..string.char(newFlag)..eh:sub(21,52)
  newEh = newEh .. w32(crc32(newEh))
  ws(efi.offset, pad(newEh..eh:sub(57), ss))

  print("SecureBoot "..(newFlag==1 and "ENABLED" or "DISABLED"))

else
  print("Unknown command: "..cmd)
  usage()
end