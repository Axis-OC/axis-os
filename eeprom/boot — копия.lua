local PK_FINGERPRINT = "%%PK_FP%%"
local EXPECTED_KERNEL_HASH = "%%KERN_H%%"
local MACHINE_BINDING = "%%MACH_B%%"
local MANIFEST_HASH = "%%MANIF_H%%"

local c = component
local cp = computer
local eeprom = c.list("eeprom")()
local gpu_addr = c.list("gpu")()
local scr_addr = c.list("screen")()
local fs_addr = c.list("filesystem")()
local data_addr = c.list("data")()

local W, H = 80, 25
if gpu_addr and scr_addr then
  local g = c.proxy(gpu_addr)
  g.bind(scr_addr)
  W, H = g.getResolution()
  g.setBackground(0x000000)
  g.setForeground(0xFFFFFF)
  g.fill(1, 1, W, H, " ")
end

local function gpu_print(y, text, color)
  if not gpu_addr then return end
  local g = c.proxy(gpu_addr)
  if color then g.setForeground(color) end
  g.set(2, y, tostring(text))
end

local function halt(reason)
  gpu_print(H-2, "SECURE BOOT FAILURE", 0xFF0000)
  gpu_print(H-1, reason, 0xFF5555)
  gpu_print(H, "System halted. Hardware intervention required.", 0xAAAAAA)
  cp.beep(200, 2)
  while true do cp.pullSignal(math.huge) end
end

gpu_print(1, "AxisOS Secure Boot v1.0", 0x00BCD4)
gpu_print(2, string.rep("=", 40), 0x333333)
gpu_print(4, "[0/4] Verifying boot ROM integrity...", 0xAAAAAA)

local eep = c.proxy(eeprom)
local stored_data = eep.getData()
if not stored_data or #stored_data < 64 then
  halt("EEPROM data area corrupt or empty")
end

gpu_print(5, "[1/4] Validating machine binding...", 0xAAAAAA)

if not data_addr then
  halt("NO DATA CARD: Cannot establish machine identity")
end

local data = c.proxy(data_addr)

local machine_id = data.sha256(
  data_addr ..
  eeprom ..
  (fs_addr or "NO_FS")
)

local function to_hex(s)
  local t = {}
  for i = 1, #s do t[i] = string.format("%02x", s:byte(i)) end
  return table.concat(t)
end

local current_binding = to_hex(machine_id)

if MACHINE_BINDING ~= "%%MACH_B%%" then
  if current_binding ~= MACHINE_BINDING then
    halt("MACHINE BINDING MISMATCH\nExpected: " ..
         MACHINE_BINDING:sub(1,16) .. "...\nGot:      " ..
         current_binding:sub(1,16) .. "...\n" ..
         "Hardware was changed. Re-provisioning required.")
  end
  gpu_print(5, "[1/4] Machine binding: VERIFIED", 0x00FF00)
else
  gpu_print(5, "[1/4] Machine binding: FIRST BOOT (unbound)", 0xFFAA00)
end

gpu_print(6, "[2/4] Measuring kernel...", 0xAAAAAA)

if not fs_addr then halt("NO FILESYSTEM") end
local fs = c.proxy(fs_addr)

local kh = fs.open("/kernel.lua", "r")
if not kh then halt("KERNEL NOT FOUND: /kernel.lua missing") end

local chunks = {}
while true do
  local chunk = fs.read(kh, 8192)
  if not chunk then break end
  chunks[#chunks + 1] = chunk
end
fs.close(kh)
local kernel_code = table.concat(chunks)

if #kernel_code < 100 then halt("KERNEL TOO SMALL: Possibly corrupt") end

local kernel_hash = to_hex(data.sha256(kernel_code))

if EXPECTED_KERNEL_HASH ~= "%%KERN_H%%" then
  if kernel_hash ~= EXPECTED_KERNEL_HASH then
    halt("KERNEL HASH MISMATCH\n" ..
         "Expected: " .. EXPECTED_KERNEL_HASH:sub(1,16) .. "...\n" ..
         "Actual:   " .. kernel_hash:sub(1,16) .. "...\n" ..
         "Kernel has been MODIFIED. Refusing to boot.")
  end
  gpu_print(6, "[2/4] Kernel integrity: VERIFIED (" .. kernel_hash:sub(1,8) .. "...)", 0x00FF00)
else
  gpu_print(6, "[2/4] Kernel hash: " .. kernel_hash:sub(1,16) .. " (unverified)", 0xFFAA00)
end

gpu_print(7, "[3/4] Checking boot manifest...", 0xAAAAAA)

local mh = fs.open("/boot/manifest.sig", "r")
if mh then
  local mdata = ""
  while true do
    local chunk = fs.read(mh, 8192)
    if not chunk then break end
    mdata = mdata .. chunk
  end
  fs.close(mh)
  
  local manifest_hash = to_hex(data.sha256(mdata))
  if MANIFEST_HASH ~= "%%MANIF_H%%" and manifest_hash ~= MANIFEST_HASH then
    halt("BOOT MANIFEST TAMPERED")
  end
  gpu_print(7, "[3/4] Boot manifest: PRESENT", 0x00FF00)
else
  if MANIFEST_HASH ~= "%%MANIF_H%%" then
    halt("BOOT MANIFEST MISSING (required by security policy)")
  end
  gpu_print(7, "[3/4] Boot manifest: NOT PRESENT (warning)", 0xFFAA00)
end

gpu_print(8, "[4/4] Loading verified kernel...", 0x00BCD4)
gpu_print(10, "Trust chain: EEPROM -> kernel -> PM -> drivers", 0x555555)

_G.boot_security = {
  machine_binding = current_binding,
  kernel_hash = kernel_hash,
  data_card_addr = data_addr,
  pk_fingerprint = PK_FINGERPRINT,
  verified = (EXPECTED_KERNEL_HASH ~= "%%KERN_H%%"),
  sealed = (MACHINE_BINDING ~= "%%MACH_B%%"),
}

_G.boot_fs_address = fs_addr
_G.boot_args = {}

local fn, err = load(kernel_code, "=kernel", "t", _G)
if not fn then halt("KERNEL LOAD ERROR: " .. tostring(err)) end

local ok, err = xpcall(fn, debug.traceback)
if not ok then halt("KERNEL PANIC: " .. tostring(err)) end