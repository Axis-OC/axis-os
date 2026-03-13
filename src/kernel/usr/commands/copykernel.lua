--
-- /usr/commands/copykernel.lua
-- Copies /kernel.lua onto the DH0 partition of an AXFS drive
--

local fs  = require("filesystem")
local AX  = require("axfs_core")
local RDB = require("rdb")
local B   = require("bpack")

-- 1. Read kernel from current filesystem
io.write("Reading /kernel.lua... ")
local hK = fs.open("/kernel.lua", "r")
if not hK then print("FAIL: cannot open /kernel.lua"); return end
local tC = {}
while true do
    local s = fs.read(hK, 4096)
    if not s then break end
    tC[#tC + 1] = s
end
fs.close(hK)
local sKernel = table.concat(tC)
print(#sKernel .. " bytes")

-- 2. Find a drive with RDB + AXFS
io.write("Scanning drives... ")
local tDrives = fs.list("/dev")
local hDev, sDev
if tDrives then
    for _, sName in ipairs(tDrives) do
        local sClean = sName:gsub("/$", "")
        if sClean:find("drive", 1, true) then
            local sPath = "/dev/" .. sClean
            local h = fs.open(sPath, "r")
            if h then
                local bOk, tInfo = fs.deviceControl(h, "info", {})
                if bOk and tInfo then
                    -- Check for RDB
                    local bR, sS0 = fs.deviceControl(h, "read_sector", {1})
                    if bR and sS0 and #sS0 >= 4 and sS0:sub(1, 4) == "RDSK" then
                        hDev = h
                        sDev = sPath
                        break
                    end
                end
                if not hDev then fs.close(h) end
            end
        end
    end
end

if not hDev then print("FAIL: no RDB drive found"); return end
print("found " .. sDev)

-- 3. Build disk interface
local bI, tI = fs.deviceControl(hDev, "info", {})
local ss = tI.sectorSize
local tDisk = {
    sectorSize = ss,
    sectorCount = tI.sectorCount,
    readSector = function(n)
        local bOk, d = fs.deviceControl(hDev, "read_sector", {n + 1})
        return bOk and d or nil
    end,
    writeSector = function(n, d)
        d = B.pad(d or "", ss)
        return fs.deviceControl(hDev, "write_sector", {n + 1, d:sub(1, ss)})
    end,
}

-- 4. Read RDB, find DH0 / first AXFS partition
io.write("Reading RDB... ")
local tRdb = RDB.read(tDisk)
if not tRdb then print("FAIL: cannot parse RDB"); fs.close(hDev); return end
print(#tRdb.partitions .. " partition(s)")

local nAxIdx
for i, p in ipairs(tRdb.partitions) do
    if p.fsType == RDB.FS_AXFS2 then
        nAxIdx = i
        break
    end
end
if not nAxIdx then print("FAIL: no AXFS v2 partition"); fs.close(hDev); return end

local p = tRdb.partitions[nAxIdx]
print("AXFS partition: " .. (p.deviceName or "DH0") ..
    " @ sector " .. p.startSector .. " (" .. p.sizeSectors .. " sectors)")

-- 5. Mount AXFS volume
io.write("Mounting... ")
local tPD = {
    sectorSize = ss,
    sectorCount = p.sizeSectors,
    readSector = function(n) return tDisk.readSector(p.startSector + n) end,
    writeSector = function(n, d) return tDisk.writeSector(p.startSector + n, d) end,
}
local vol, vErr = AX.mount(tPD, {cacheSize = 32})
if not vol then print("FAIL: " .. tostring(vErr)); fs.close(hDev); return end
print("OK (" .. vol.su.label .. ")")

-- 6. Write kernel
io.write("Writing /kernel.lua (" .. #sKernel .. " bytes)... ")
syscall("process_yield")
local bW, sWErr = vol:writeFile("/kernel.lua", sKernel)
if not bW then print("FAIL: " .. tostring(sWErr)); fs.close(hDev); return end
print("OK")

-- 7. Verify
io.write("Verifying... ")
local sRead = vol:readFile("/kernel.lua")
if sRead and #sRead == #sKernel then
    print("OK — " .. #sRead .. " bytes match")
else
    print("MISMATCH! wrote=" .. #sKernel .. " read=" .. tostring(sRead and #sRead or "nil"))
end

-- 8. Flush and close
io.write("Flushing... ")
vol:flush()
fs.close(hDev)
print("Done.")