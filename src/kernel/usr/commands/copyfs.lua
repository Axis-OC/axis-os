--
-- /usr/commands/copyfs.lua
-- Copies any file onto the DH0 partition of an AXFS drive
--
-- Usage: copyfs <source_path> [dest_path]
--   copyfs /boot/sys/stage2_boot.lua
--   copyfs /boot/kbl_shell.lua /boot/kbl_shell.lua
--
-- If dest_path is omitted, the file is written to the same path.
--

local fs  = require("filesystem")
local AX  = require("axfs_core")
local RDB = require("rdb")
local B   = require("bpack")
local args = env.ARGS or {}

local sSrc  = args[1]
local sDest = args[2] or sSrc

if not sSrc or #sSrc == 0 then
    print("Usage: copyfs <source_path> [dest_path]")
    print("  Copies a file from the running OS onto the AXFS drive.")
    print("  If dest_path is omitted, uses the same path as source.")
    return
end

-- 1. Read source file
io.write("Reading " .. sSrc .. "... ")
local hSrc = fs.open(sSrc, "r")
if not hSrc then print("FAIL: cannot open " .. sSrc); return end
local tC = {}
while true do
    local s = fs.read(hSrc, 4096)
    if not s then break end
    tC[#tC + 1] = s
end
fs.close(hSrc)
local sData = table.concat(tC)
if #sData == 0 then print("FAIL: file is empty"); return end
print(#sData .. " bytes")

-- 2. Find a drive with RDB
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
                    local bR, sS0 = fs.deviceControl(h, "read_sector", {1})
                    if bR and sS0 and #sS0 >= 4 and sS0:sub(1, 4) == "RDSK" then
                        hDev = h; sDev = sPath; break
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
    sectorSize = ss, sectorCount = tI.sectorCount,
    readSector = function(n)
        local bOk, d = fs.deviceControl(hDev, "read_sector", {n + 1})
        return bOk and d or nil
    end,
    writeSector = function(n, d)
        d = B.pad(d or "", ss)
        return fs.deviceControl(hDev, "write_sector", {n + 1, d:sub(1, ss)})
    end,
}

-- 4. Read RDB, find first AXFS v2 partition
io.write("Reading RDB... ")
local tRdb = RDB.read(tDisk)
if not tRdb then print("FAIL: cannot parse RDB"); fs.close(hDev); return end
print(#tRdb.partitions .. " partition(s)")

local nAxIdx
for i, p in ipairs(tRdb.partitions) do
    if p.fsType == RDB.FS_AXFS2 then nAxIdx = i; break end
end
if not nAxIdx then print("FAIL: no AXFS v2 partition"); fs.close(hDev); return end

local p = tRdb.partitions[nAxIdx]
print("AXFS: " .. (p.deviceName or "DH0") ..
    " @ sector " .. p.startSector .. " (" .. p.sizeSectors .. " sectors)")

-- 5. Mount
io.write("Mounting... ")
local tPD = {
    sectorSize = ss, sectorCount = p.sizeSectors,
    readSector  = function(n) return tDisk.readSector(p.startSector + n) end,
    writeSector = function(n, d) return tDisk.writeSector(p.startSector + n, d) end,
}
local vol, vErr = AX.mount(tPD, {cacheSize = 32})
if not vol then print("FAIL: " .. tostring(vErr)); fs.close(hDev); return end
print("OK (" .. vol.su.label .. ")")

-- 6. Ensure parent directories exist
local tSegs = {}
for seg in sDest:gmatch("[^/]+") do tSegs[#tSegs + 1] = seg end
if #tSegs > 1 then
    local sDir = ""
    for i = 1, #tSegs - 1 do
        sDir = sDir .. "/" .. tSegs[i]
        if not vol:stat(sDir) then
            vol:mkdir(sDir)
        end
    end
end

-- 7. Write file
io.write("Writing " .. sDest .. " (" .. #sData .. " bytes)... ")
syscall("process_yield")
local bW, sWErr = vol:writeFile(sDest, sData)
if not bW then print("FAIL: " .. tostring(sWErr)); fs.close(hDev); return end
print("OK")

-- 8. Verify
io.write("Verifying... ")
local sRead = vol:readFile(sDest)
if sRead and #sRead == #sData then
    print("OK — " .. #sRead .. " bytes match")
else
    print("MISMATCH! wrote=" .. #sData ..
        " read=" .. tostring(sRead and #sRead or "nil"))
end

-- 9. Flush and close
io.write("Flushing... ")
vol:flush()
fs.close(hDev)
print("Done.")