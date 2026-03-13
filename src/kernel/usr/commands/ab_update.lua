--
-- /usr/commands/ab_update.lua
-- Copy current running system to inactive A/B slot
--
local fs = require("filesystem")
local oSys = require("syscall")

local args = env.ARGS or {}

-- Get current boot info from kernel
local sCurrentSlot = syscall("ab_get_slot") -- returns "a" or "b"
if not sCurrentSlot then
    io.write("A/B not available (single-slot system)\n")
    return
end

local sTargetSlot = sCurrentSlot == "a" and "b" or "a"
io.write("Current slot: " .. sCurrentSlot .. "\n")
io.write("Target slot:  " .. sTargetSlot .. "\n")

-- Get drive info
local tDrives = syscall("disk_list_drives")
if not tDrives then io.write("No drives found\n"); return end

local sDriveAddr
for addr in pairs(tDrives) do sDriveAddr = addr; break end
if not sDriveAddr then io.write("No drive\n"); return end

-- Load partition libraries
local RDB = require("rdb")
local AX  = require("axfs_core")
local B   = require("bpack")

-- Open drive via blkdev
local hDev = fs.open("/dev/drive_" .. sDriveAddr:sub(1,6) .. "_0", "r")
if not hDev then
    io.write("Cannot open drive device\n"); return
end

local bI, tInfo = fs.deviceControl(hDev, "info", {})
if not bI then io.write("Cannot get drive info\n"); return end
local ss = tInfo.sectorSize

-- Read RDB
local function drs(n)
    local b, d = fs.deviceControl(hDev, "read_sector", {n})
    return b and d or nil
end
local function dws(n, d)
    return fs.deviceControl(hDev, "write_sector", {n, d})
end

local tDisk = { sectorSize = ss, readSector = drs, writeSector = dws }

-- Find both AXFS partitions
local sRdb = drs(1)
if not sRdb or sRdb:sub(1, 4) ~= "RDSK" then
    io.write("No RDB on drive\n"); fs.close(hDev); return
end

local tAxfs = {}  -- {off, sz} for each AXFS
local ns = B.ri32(sRdb, 25)
for _ = 1, 16 do
    if ns < 0 then break end
    local q = drs(ns + 1)
    if not q or q:sub(1, 4) ~= "PART" then break end
    if B.r32(q, 65) == 0x41584632 then
        tAxfs[#tAxfs + 1] = { off = B.r32(q, 57), sz = B.r32(q, 61) }
    end
    ns = B.ri32(q, 17)
end

if #tAxfs < 2 then
    io.write("Need 2 AXFS partitions for A/B update (found " .. #tAxfs .. ")\n")
    fs.close(hDev); return
end

local tSrc = tAxfs[sCurrentSlot == "a" and 1 or 2]
local tDst = tAxfs[sCurrentSlot == "a" and 2 or 1]

io.write(string.format("Source: AXFS @ sector %d (%d sectors)\n", tSrc.off, tSrc.sz))
io.write(string.format("Target: AXFS @ sector %d (%d sectors)\n", tDst.off, tDst.sz))

if tDst.sz < tSrc.sz then
    io.write("WARNING: Target partition smaller than source\n")
end

-- Confirm
io.write("\nThis will OVERWRITE slot " .. sTargetSlot .. ". Continue? [y/N] ")
local sConfirm = io.read()
if not sConfirm or sConfirm:lower() ~= "y" then
    io.write("Aborted.\n"); fs.close(hDev); return
end

-- Sector-by-sector copy
local nTotal = math.min(tSrc.sz, tDst.sz)
io.write("Copying " .. nTotal .. " sectors...\n")

local nCopied = 0
for i = 0, nTotal - 1 do
    local sData = drs(tSrc.off + i + 1)
    if sData then
        dws(tDst.off + i + 1, sData)
        nCopied = nCopied + 1
    end
    if i % 64 == 0 then
        io.write(string.format("\r  %d/%d sectors (%d%%)",
            i, nTotal, math.floor(i / nTotal * 100)))
        syscall("process_yield")
    end
end

io.write(string.format("\r  %d/%d sectors (100%%)\n", nCopied, nTotal))

-- Mark target slot as unverified (it's new, needs verification)
local bOk, sErr = syscall("ab_set_slot_state", sTargetSlot, 1)
io.write("Slot " .. sTargetSlot .. " updated and marked unverified.\n")
io.write("To boot into it: reboot, then in KBL: set_active " .. sTargetSlot .. "\n")
io.write("Or from here: syscall ab_switch_slot\n")

fs.close(hDev)