-- /usr/commands/provision.lua
-- AxisOS Secure Boot Provisioning Tool
--
-- This tool:
--   1. Generates or imports Platform Key
--   2. Computes machine binding
--   3. Hashes the current kernel
--   4. Writes EEPROM boot code with embedded constants
--   5. Optionally SEALS the EEPROM (PERMANENT, IRREVERSIBLE)
--
-- Usage:
--   provision                 Interactive provisioning
--   provision --status        Show current security state
--   provision --seal          Seal after provisioning (PERMANENT)
--   provision --update-hash   Update kernel hash only (before sealing)
--

local fs = require("filesystem")
local crypto = require("crypto")
local sys = require("syscall")
local tArgs = env.ARGS or {}

local C = {
  R="\27[37m", GRN="\27[32m", RED="\27[31m",
  CYN="\27[36m", YLW="\27[33m", GRY="\27[90m",
  MAG="\27[35m", BLU="\27[34m"
}

-- =============================================
-- DETECT HARDWARE
-- =============================================

local function getComponentProxy(sType)
    local tList = {}
    local bOk, _ = pcall(function()
        for addr in component.list(sType) do tList[addr] = true end
    end)
    if not bOk then
        pcall(function()
            for addr in raw_component.list(sType) do tList[addr] = true end
        end)
    end
    for addr in pairs(tList) do
        local p
        pcall(function() p = component.proxy(addr) end)
        if not p then pcall(function() p = raw_component.proxy(addr) end) end
        if p then return p, addr end
    end
    return nil
end

local oEeprom, sEepromAddr = getComponentProxy("eeprom")
local oData, sDataAddr = getComponentProxy("data")
local oFs, sFsAddr = getComponentProxy("filesystem")

local function to_hex(s)
    if not s then return "nil" end
    local t = {}
    for i = 1, math.min(#s, 64) do
        t[i] = string.format("%02x", s:byte(i))
    end
    return table.concat(t)
end

-- =============================================
-- STATUS CHECK
-- =============================================

if tArgs[1] == "--status" then
    print(C.CYN .. "=== AxisOS Secure Boot Status ===" .. C.R)
    print("")
    
    -- EEPROM
    if oEeprom then
        local sLabel = oEeprom.getLabel() or "(unlabeled)"
        local bReadonly = false
        -- There's no direct "isReadonly" check, but we can try writing
        -- Actually, we should NOT try writing. Check the data area instead.
        local sData = oEeprom.getData()
        print("  EEPROM:     " .. C.GRN .. "Present" .. C.R .. " [" .. sLabel .. "]")
        print("  EEPROM Addr: " .. C.GRY .. sEepromAddr .. C.R)
        
        if sData and #sData >= 64 then
            print("  Data Area:  " .. C.GRN .. #sData .. " bytes populated" .. C.R)
            print("  Binding:    " .. C.MAG .. to_hex(sData:sub(1,32)):sub(1,16) .. "..." .. C.R)
        else
            print("  Data Area:  " .. C.YLW .. "Empty (not provisioned)" .. C.R)
        end
    else
        print("  EEPROM:     " .. C.RED .. "NOT FOUND" .. C.R)
    end
    
    -- Data Card
    if oData then
        local nTier = 1
        if oData.ecdsa then nTier = 3 elseif oData.encrypt then nTier = 2 end
        print("  Data Card:  " .. C.GRN .. "Tier " .. nTier .. C.R)
        print("  Card Addr:  " .. C.GRY .. sDataAddr .. C.R)
    else
        print("  Data Card:  " .. C.RED .. "NOT FOUND (security degraded)" .. C.R)
    end
    
    -- Filesystem
    if oFs then
        print("  Root FS:    " .. C.GRN .. "Present" .. C.R)
        print("  FS Addr:    " .. C.GRY .. sFsAddr .. C.R)
    end
    
    -- Kernel hash
    if oFs and oData then
        local kh = oFs.open("/kernel.lua", "r")
        if kh then
            local chunks = {}
            while true do
                local chunk = oFs.read(kh, 8192)
                if not chunk then break end
                chunks[#chunks+1] = chunk
            end
            oFs.close(kh)
            local hash = to_hex(oData.sha256(table.concat(chunks)))
            print("  Kernel Hash: " .. C.CYN .. hash:sub(1,32) .. "..." .. C.R)
        end
    end
    
    -- Boot manifest
    if oFs then
        local mh = oFs.open("/boot/manifest.sig", "r")
        if mh then
            oFs.close(mh)
            print("  Manifest:   " .. C.GRN .. "Present" .. C.R)
        else
            print("  Manifest:   " .. C.YLW .. "Missing" .. C.R)
        end
    end
    
    print("")
    return
end

-- =============================================
-- PROVISION
-- =============================================

print("")
print(C.CYN .. "╔══════════════════════════════════════════════╗" .. C.R)
print(C.CYN .. "║  AxisOS Secure Boot Provisioning Tool        ║" .. C.R)
print(C.CYN .. "╚══════════════════════════════════════════════╝" .. C.R)
print("")

-- Checks
if not oEeprom then
    print(C.RED .. "FATAL: No EEPROM component found." .. C.R)
    return
end
if not oData then
    print(C.RED .. "FATAL: No Data Card found. Tier 3 required for full security." .. C.R)
    return
end
if not oFs then
    print(C.RED .. "FATAL: No filesystem." .. C.R)
    return
end

local nTier = 1
if oData.ecdsa then nTier = 3 elseif oData.encrypt then nTier = 2 end
if nTier < 3 then
    print(C.YLW .. "WARNING: Data Card is Tier " .. nTier ..
          ". Tier 3 required for ECDSA signatures." .. C.R)
    print(C.YLW .. "Proceeding with hash-only verification." .. C.R)
end

print(C.GRN .. "[1/5]" .. C.R .. " Computing machine binding...")
local machine_binding = to_hex(oData.sha256(
    sDataAddr .. sEepromAddr .. sFsAddr
))
print("  Binding: " .. C.MAG .. machine_binding:sub(1,16) .. "..." .. C.R)

print(C.GRN .. "[2/5]" .. C.R .. " Hashing kernel...")
local kh = fs.open("/kernel.lua", "r")
if not kh then print(C.RED .. "FATAL: /kernel.lua not found" .. C.R); return end
local chunks = {}
while true do
    local chunk = fs.read(kh, 8192)
    if not chunk then break end
    chunks[#chunks+1] = chunk
end
fs.close(kh)
local kernel_hash = to_hex(oData.sha256(table.concat(chunks)))
print("  Kernel: " .. C.CYN .. kernel_hash:sub(1,16) .. "..." .. C.R)

print(C.GRN .. "[3/5]" .. C.R .. " Platform Key...")
local pk_fp = "NONE"
if nTier >= 3 then
    -- Check for existing PK
    local pkFile = oFs.open("/etc/signing/platform.pub", "r")
    if pkFile then
        local pkData = ""
        while true do
            local c = oFs.read(pkFile, 4096)
            if not c then break end
            pkData = pkData .. c
        end
        oFs.close(pkFile)
        pk_fp = to_hex(oData.sha256(pkData))
        print("  PK Fingerprint: " .. C.MAG .. pk_fp:sub(1,16) .. "..." .. C.R)
    else
        print("  " .. C.YLW .. "No platform key found. Generate with: sign -g" .. C.R)
    end
end

print(C.GRN .. "[4/5]" .. C.R .. " Boot manifest hash...")
local manifest_hash = "NONE"
local mh = oFs.open("/boot/manifest.sig", "r")
if mh then
    local mdata = ""
    while true do
        local c = oFs.read(mh, 8192)
        if not c then break end
        mdata = mdata .. c
    end
    oFs.close(mh)
    manifest_hash = to_hex(oData.sha256(mdata))
    print("  Manifest: " .. C.CYN .. manifest_hash:sub(1,16) .. "..." .. C.R)
else
    print("  " .. C.YLW .. "No manifest. Create with: manifest --generate" .. C.R)
end

-- Read the EEPROM boot template
print(C.GRN .. "[5/5]" .. C.R .. " Reading boot ROM template...")
local bh = oFs.open("/boot/eeprom_template.lua", "r")
if not bh then
    print(C.RED .. "FATAL: /boot/eeprom_template.lua not found" .. C.R)
    print("  Place the sealed EEPROM boot code template at this path.")
    return
end
local boot_template = ""
while true do
    local c = oFs.read(bh, 4096)
    if not c then break end
    boot_template = boot_template .. c
end
oFs.close(bh)

local boot_code = boot_template
boot_code = boot_code:gsub("%%%%PK_FP%%%%", pk_fp)
boot_code = boot_code:gsub("%%%%KERN_H%%%%", kernel_hash)
boot_code = boot_code:gsub("%%%%MACH_B%%%%", machine_binding)
boot_code = boot_code:gsub("%%%%MANIF_H%%%%", manifest_hash)

if #boot_code > 4096 then
    print(C.RED .. "FATAL: Boot code too large (" .. #boot_code ..
          " bytes, max 4096)" .. C.R)
    return
end

print("")
print(C.YLW .. "  Boot code size: " .. #boot_code .. " / 4096 bytes" .. C.R)
print("")
print(C.CYN .. "╔══════════════════════════════════════════════╗" .. C.R)
print(C.CYN .. "║  PROVISIONING SUMMARY                        ║" .. C.R)
print(C.CYN .. "╠══════════════════════════════════════════════╣" .. C.R)
print(C.CYN .. "║" .. C.R .. "  Machine Binding: " ..
      C.MAG .. machine_binding:sub(1,24) .. "..." .. C.CYN .. "  ║" .. C.R)
print(C.CYN .. "║" .. C.R .. "  Kernel Hash:     " ..
      C.GRN .. kernel_hash:sub(1,24) .. "..." .. C.CYN .. "  ║" .. C.R)
print(C.CYN .. "║" .. C.R .. "  Platform Key:    " ..
      (pk_fp ~= "NONE" and (C.GRN .. pk_fp:sub(1,24) .. "...") or (C.YLW .. "NONE")) ..
      C.CYN .. "  ║" .. C.R)
print(C.CYN .. "╚══════════════════════════════════════════════╝" .. C.R)

print("")
print(C.RED .. "  WARNING: This will overwrite the EEPROM." .. C.R)
print(C.RED .. "  Type 'PROVISION' to confirm:" .. C.R)
io.write("  > ")
local confirm = io.read()
if confirm ~= "PROVISION" then
    print(C.YLW .. "Aborted." .. C.R)
    return
end

-- Write EEPROM
print("")
print("  Writing EEPROM code...")
oEeprom.set(boot_code)

-- Write EEPROM data area (binary packed binding info)
local eeprom_data = machine_binding:sub(1,64)  -- 64 hex chars = 32 bytes binding
-- Pad to use data area efficiently
while #eeprom_data < 256 do
    eeprom_data = eeprom_data .. "\0"
end
oEeprom.setData(eeprom_data)

oEeprom.setLabel("AxisOS SecureBoot v1.0")

print(C.GRN .. "  EEPROM written successfully." .. C.R)

-- === SEAL ===
if tArgs[1] == "--seal" then
    print("")
    print(C.RED .. "  ╔═══════════════════════════════════════╗" .. C.R)
    print(C.RED .. "  ║  SEALING EEPROM                       ║" .. C.R)
    print(C.RED .. "  ║  THIS IS PERMANENT AND IRREVERSIBLE   ║" .. C.R)
    print(C.RED .. "  ║                                       ║" .. C.R)
    print(C.RED .. "  ║  The EEPROM can NEVER be modified     ║" .. C.R)
    print(C.RED .. "  ║  again on this hardware.              ║" .. C.R)
    print(C.RED .. "  ╚═══════════════════════════════════════╝" .. C.R)
    print("")
    print(C.RED .. "  Type 'SEAL' to make EEPROM read-only:" .. C.R)
    io.write("  > ")
    local seal_confirm = io.read()
    
    if seal_confirm == "SEAL" then
        -- Compute checksum for makeReadonly
        local checksum = oData.sha256(boot_code)
        local bOk, sErr = pcall(function()
            oEeprom.makeReadonly(checksum)
        end)
        
        if bOk then
            print(C.GRN .. "" .. C.R)
            print(C.GRN .. "  EEPROM SEALED SUCCESSFULLY" .. C.R)
            print(C.GRN .. "  This machine now has an immutable root of trust." .. C.R)
            print(C.GRN .. "" .. C.R)
        else
            print(C.RED .. "  Seal failed: " .. tostring(sErr) .. C.R)
        end
    else
        print(C.YLW .. "  Seal cancelled. EEPROM is written but NOT sealed." .. C.R)
        print(C.YLW .. "  Run 'provision --seal' when ready." .. C.R)
    end
else
    print("")
    print(C.YLW .. "  EEPROM is writable (not sealed)." .. C.R)
    print(C.YLW .. "  To seal permanently: provision --seal" .. C.R)
end

print("")