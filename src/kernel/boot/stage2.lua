-- /boot/stage2.lua
-- Stage 2: EFI Decryptor Bridge
local c, p = component, computer
local D = c.proxy(_efi_drive)

-- Find AXEFI partition in RDB
local rdb = D.readSector(1)
local efiOff, efiSz
local np = rdb:byte(6)
for i=0, np-1 do
    local o = 9 + i * 32
    local pt = rdb:sub(o, o+4):gsub("\0","")
    if pt == "AXEFI" then
        efiOff = (rdb:byte(o+8)*0x1000000 + rdb:byte(o+9)*0x10000 + rdb:byte(o+10)*0x100 + rdb:byte(o+11))
        efiSz  = (rdb:byte(o+12)*0x1000000 + rdb:byte(o+13)*0x10000 + rdb:byte(o+14)*0x100 + rdb:byte(o+15))
        break
    end
end

if not efiOff then error("PANIC: No AXEFI partition found in RDB.") end

local dcAddr = c.list("data")()
if not dcAddr then error("PANIC: Data Card required for SecureBoot decryption.") end
local dc = c.proxy(dcAddr)

-- Decrypt EFI Payload (AES or HMAC-XOR using Machine Binding)
local binding = dc.sha256(p.address() .. dcAddr)

-- Read EFI contents
local ss = D.getSectorSize()
local tEfi = {}
for i=0, efiSz-1 do
    tEfi[#tEfi+1] = D.readSector(efiOff + i + 1)
end
local rawEfi = table.concat(tEfi)

-- Simple XOR keystream decryption using machine binding as seed
local decrypted = {}
for i=1, #rawEfi do
    local keyByte = binding:byte((i % 32) + 1)
    decrypted[i] = string.char(bit32.bxor(rawEfi:byte(i), keyByte))
end
local s3Code = table.concat(decrypted)

local env = setmetatable({ component=c, computer=p, boot_fs_address=boot_fs_address }, {__index=_G})
local fn, err = load(s3Code, "=efi_stage3", "t", env)
if not fn then error("PANIC: EFI Stage 3 corrupted or wrong machine binding.") end
fn()