--
-- /usr/commands/axfs_flash.lua
-- Flash the AXFS bootloader to EEPROM
--
local fs = require("filesystem")
local tArgs = env.ARGS or {}

local C = {R="\27[37m", G="\27[32m", E="\27[31m", Y="\27[33m", C="\27[36m"}

local function getProxy(sType)
  local bOk, tList = syscall("raw_component_list", sType)
  if bOk and tList then
    for addr in pairs(tList) do
      local _, p = pcall(function() return raw_component.proxy(addr) end)
      if not p then _, p = pcall(function() return component.proxy(addr) end) end
      if p then return p, addr end
    end
  end
end

local oEep = getProxy("eeprom")
if not oEep then print(C.E .. "No EEPROM found!" .. C.R); return end

local sBoot = "/boot/axfs_boot.lua"
if tArgs[1] then sBoot = tArgs[1] end

local h = fs.open(sBoot, "r")
if not h then print(C.E .. "Cannot read " .. sBoot .. C.R); return end
local tC = {}
while true do
  local s = fs.read(h, math.huge); if not s then break end; tC[#tC+1] = s
end
fs.close(h)
local sCode = table.concat(tC)

if #sCode > 4096 then
  print(C.E .. "Boot code too large: " .. #sCode .. " bytes (max 4096)" .. C.R)
  return
end

print(C.C .. "Flashing AXFS bootloader..." .. C.R)
print("  Source: " .. sBoot)
print("  Size:   " .. #sCode .. " / 4096 bytes")
print("")

print(C.Y .. "  This will overwrite the EEPROM." .. C.R)
print(C.Y .. "  Type 'FLASH' to confirm:" .. C.R)
io.write("  > ")
local sConfirm = io.read()
if sConfirm ~= "FLASH" then print("  Aborted."); return end

oEep.set(sCode)
oEep.setLabel("AxisOS AXFS Boot")

print("")
print(C.G .. "  EEPROM flashed successfully!" .. C.R)
print("  Reboot to boot from AXFS.")