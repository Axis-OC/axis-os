--
-- /usr/commands/kblflash.lua
-- KBL Partition Flash Tool for AxisOS
--
-- Flashes stage2_boot.lua, kbl_shell.lua, and loader.cfg
-- into the KBL partition. Creates KBL partition if absent.
--
-- Works on managed FS (standard OC filesystem root).
-- Requires blkdev driver loaded (insmod blkdev).
--
-- Usage:
--   kblflash                     (auto-detect drive)
--   kblflash /dev/drive_xxxx     (specific drive)
--   kblflash --dry-run            (show plan without writing)
--   kblflash --force              (skip confirmation)
--

local fs  = require("filesystem")
local RDB = require("rdb")
local B   = require("bpack")
local args = env.ARGS or {}

-- =============================================
-- CONFIG
-- =============================================

local KBL_MIN_SECTORS  = 128
local KBL_DEFAULT_SIZE = 128

local LAYOUT = {
    LOADER_START = 1,  LOADER_COUNT = 3,
    STAGE2_START = 4,  STAGE2_COUNT = 47,
    SHELL_START  = 51, SHELL_COUNT  = 70,
    VAR_START    = 121, VAR_COUNT   = 4,
}


local STAGE2_PATHS = {
    "/boot/sys/stage2_boot.lua",
    "/boot/stage2_boot.lua",
    "/system/stage2_boot.lua",
}

local SHELL_PATHS = {
    "/boot/kbl_shell.lua",
    "/lib/kbl_shell.lua",
    "/system/kbl_shell.lua",
    "/boot/sys/kbl_shell.lua",
}

local LOADER_PATH = "/boot/loader.cfg"

-- =============================================
-- PARSE ARGS
-- =============================================

local sTargetDev = nil
local bDryRun    = false
local bForce     = false

for _, sArg in ipairs(args) do
    if sArg == "--dry-run" or sArg == "-n" then
        bDryRun = true
    elseif sArg == "--force" or sArg == "-f" then
        bForce = true
    elseif sArg == "--help" or sArg == "-h" then
        print("kblflash — Flash KBL partition on unmanaged drive")
        print("")
        print("Usage:")
        print("  kblflash                     Auto-detect drive")
        print("  kblflash /dev/drive_xxxx     Specific drive")
        print("  kblflash --dry-run           Show plan, don't write")
        print("  kblflash --force             Skip confirmation")
        print("")
        print("Reads stage2, shell, loader.cfg from filesystem,")
        print("writes them into KBL partition raw sectors.")
        print("Creates KBL partition if not present (needs free space).")
        return
    elseif sArg:sub(1, 5) == "/dev/" then
        sTargetDev = sArg
    end
end

-- =============================================
-- HELPERS
-- =============================================

local function fmtSz(n)
    if not n or n < 0 then return "0 B" end
    if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
    if n >= 1024 then return string.format("%.1f KB", n / 1024) end
    return n .. " B"
end

local function readFile(sPath)
    local h = fs.open(sPath, "r")
    if not h then return nil end
    local tC = {}
    while true do
        local s = fs.read(h, 4096)
        if not s then break end
        tC[#tC + 1] = s
    end
    fs.close(h)
    local sData = table.concat(tC)
    return #sData > 0 and sData or nil
end

local function findFile(tPaths)
    for _, sPath in ipairs(tPaths) do
        local sData = readFile(sPath)
        if sData then return sData, sPath end
    end
    return nil, nil
end

local C_RED    = "\27[31m"
local C_GREEN  = "\27[32m"
local C_YELLOW = "\27[33m"
local C_CYAN   = "\27[36m"
local C_RESET  = "\27[37m"
local C_BOLD   = "\27[1m"

local function info(s)  io.write(C_CYAN   .. "[INFO] " .. C_RESET .. s .. "\n") end
local function ok(s)    io.write(C_GREEN  .. "[ OK ] " .. C_RESET .. s .. "\n") end
local function warn(s)  io.write(C_YELLOW .. "[WARN] " .. C_RESET .. s .. "\n") end
local function fail(s)  io.write(C_RED    .. "[FAIL] " .. C_RESET .. s .. "\n") end

-- =============================================
-- DRIVE DISCOVERY
-- =============================================

local function findDrives()
    local tDrives = {}
    local tDevList = fs.list("/dev")
    if not tDevList then return tDrives end
    for _, sName in ipairs(tDevList) do
        local sClean = sName:gsub("/$", "")
        if sClean:find("drive", 1, true) then
            local sPath = "/dev/" .. sClean
            local hD = fs.open(sPath, "r")
            if hD then
                local bI, tI = fs.deviceControl(hD, "info", {})
                fs.close(hD)
                if bI and tI then
                    tDrives[#tDrives + 1] = {
                        path       = sPath,
                        capacity   = tI.capacity or (tI.sectorCount * tI.sectorSize),
                        sectors    = tI.sectorCount,
                        secSize    = tI.sectorSize,
                    }
                end
            end
        end
    end
    return tDrives
end

-- =============================================
-- DISK I/O WRAPPER
-- =============================================

local g_hDev = nil
local g_nSS  = 512

local function openDrive(sPath)
    local h = fs.open(sPath, "r")
    if not h then return nil, "Cannot open " .. sPath end
    local bI, tI = fs.deviceControl(h, "info", {})
    if not bI or not tI then
        fs.close(h)
        return nil, "Cannot get device info"
    end
    g_hDev = h
    g_nSS  = tI.sectorSize
    return {
        sectorSize  = tI.sectorSize,
        sectorCount = tI.sectorCount,
        capacity    = tI.capacity,
        readSector = function(n)
            local bOk, d = fs.deviceControl(h, "read_sector", {n + 1})
            return bOk and d or nil
        end,
        writeSector = function(n, d)
            d = B.pad(d or "", tI.sectorSize)
            return fs.deviceControl(h, "write_sector", {n + 1, d:sub(1, tI.sectorSize)})
        end,
    }
end

local function closeDrive()
    if g_hDev then fs.close(g_hDev); g_hDev = nil end
end

-- =============================================
-- KBL PARTITION CREATION
-- =============================================

local function createKblPartition(tDisk, tRdb)
    if #tRdb.partitions >= RDB.MAX_PARTS then
        return nil, "Maximum partition count reached (" .. RDB.MAX_PARTS .. ")"
    end

    local nKblSize = KBL_DEFAULT_SIZE

    -- Strategy 1: Free space at end of disk
    local nFreeStart = RDB.nextFree(tRdb)
    local nFreeSpace = tRdb.totalSectors - nFreeStart

    if nFreeSpace >= nKblSize then
        info(string.format("Using %d free sectors at end of disk (sector %d)",
            nFreeSpace, nFreeStart))

        table.insert(tRdb.partitions, {
            deviceName  = "KBL0",
            fsLabel     = "KBL",
            startSector = nFreeStart,
            sizeSectors = nKblSize,
            fsType      = 0x41584B42,
            flags       = RDB.PF_HIDDEN_FS + RDB.PF_SYSTEM,
            bootPriority = -1,
            reserved    = 0,
            ext = {
                visibility    = RDB.VIS_SYSTEM,
                encryptType   = RDB.ENC_NONE,
                bootRole      = 5,
                integrityMode = RDB.INTEGRITY_CRC32,
                extVersion    = 1,
            },
        })

        RDB.write(tDisk, tRdb)
        local tNewRdb = RDB.read(tDisk)
        if not tNewRdb then return nil, "RDB re-read failed" end
        for _, p in ipairs(tNewRdb.partitions) do
            if p.fsType == 0x41584B42 then return p end
        end
        return nil, "KBL not found after creation"
    end

    -- Strategy 2: Shrink the last AXFS partition to make room
    -- Find the rightmost AXFS partition (the main data partition)
    local nAxfsIdx = nil
    local nAxfsEnd = 0
    for i, p in ipairs(tRdb.partitions) do
        if p.fsType == RDB.FS_AXFS2 or p.fsType == RDB.FS_AXFS1 then
            local nEnd = p.startSector + p.sizeSectors
            if nEnd > nAxfsEnd then
                nAxfsEnd = nEnd
                nAxfsIdx = i
            end
        end
    end

    if not nAxfsIdx then
        return nil, "No free space and no AXFS partition to shrink"
    end

    local tAxfs = tRdb.partitions[nAxfsIdx]

    -- Verify AXFS is large enough to lose KBL_DEFAULT_SIZE sectors
    local nMinAxfs = 128  -- absolute minimum AXFS size
    if tAxfs.sizeSectors - nKblSize < nMinAxfs then
        return nil, string.format(
            "AXFS partition too small to shrink: %d sectors, need %d for KBL + %d minimum",
            tAxfs.sizeSectors, nKblSize, nMinAxfs)
    end

    -- Check that the tail of AXFS is actually at end of disk
    -- (no other partition after it)
    local nAxfsEndSector = tAxfs.startSector + tAxfs.sizeSectors
    local bTailIsFree = true
    for i, p in ipairs(tRdb.partitions) do
        if i ~= nAxfsIdx and p.startSector >= nAxfsEndSector then
            bTailIsFree = false
            break
        end
    end

    if not bTailIsFree then
        return nil, "AXFS is not the last partition — cannot shrink safely"
    end

    -- ═══ SHRINK AXFS ═══
    local nOldSize = tAxfs.sizeSectors
    local nNewSize = nOldSize - nKblSize
    local nKblStart = tAxfs.startSector + nNewSize

    warn(string.format("Shrinking AXFS partition: %d → %d sectors (-%d)",
        nOldSize, nNewSize, nKblSize))
    warn(string.format("KBL will be created at sector %d", nKblStart))

    -- Update AXFS size in RDB
    tAxfs.sizeSectors = nNewSize

    -- Add KBL partition
    table.insert(tRdb.partitions, {
        deviceName  = "KBL0",
        fsLabel     = "KBL",
        startSector = nKblStart,
        sizeSectors = nKblSize,
        fsType      = 0x41584B42,
        flags       = RDB.PF_HIDDEN_FS + RDB.PF_SYSTEM,
        bootPriority = -1,
        reserved    = 0,
        ext = {
            visibility    = RDB.VIS_SYSTEM,
            encryptType   = RDB.ENC_NONE,
            bootRole      = 5,
            integrityMode = RDB.INTEGRITY_CRC32,
            extVersion    = 1,
        },
    })

    -- Write updated RDB
    RDB.write(tDisk, tRdb)

    -- Verify
    local tNewRdb = RDB.read(tDisk)
    if not tNewRdb then return nil, "RDB re-read failed after AXFS shrink" end

    -- Confirm AXFS was shrunk
    local bAxfsShrunk = false
    for _, p in ipairs(tNewRdb.partitions) do
        if (p.fsType == RDB.FS_AXFS2 or p.fsType == RDB.FS_AXFS1)
           and p.sizeSectors == nNewSize then
            bAxfsShrunk = true
            break
        end
    end
    if not bAxfsShrunk then
        return nil, "AXFS shrink verification failed"
    end

    -- Find the new KBL
    for _, p in ipairs(tNewRdb.partitions) do
        if p.fsType == 0x41584B42 then
            ok(string.format("AXFS shrunk by %d sectors, KBL created at sector %d",
                nKblSize, p.startSector))
            return p
        end
    end
    return nil, "KBL not found after creation + AXFS shrink"
end

-- =============================================
-- KBL FLASH
-- =============================================

local function flashKbl(tDisk, nKblOff, nKblSize, sStage2, sShell, sLoaderCfg)
    local ss = tDisk.sectorSize

    -- Validate sizes
    local nS2Secs = math.ceil(#sStage2 / ss)
    if nS2Secs > LAYOUT.STAGE2_COUNT then
        return false, string.format("Stage2 too large: %d bytes (%d sectors > %d max)",
            #sStage2, nS2Secs, LAYOUT.STAGE2_COUNT)
    end

    local nShSecs = 0
    if sShell and #sShell > 0 then
        nShSecs = math.ceil(#sShell / ss)
        if nShSecs > LAYOUT.SHELL_COUNT then
            warn(string.format("Shell truncated: %d bytes (%d > %d sectors)",
                #sShell, nShSecs, LAYOUT.SHELL_COUNT))
            nShSecs = LAYOUT.SHELL_COUNT
            sShell = sShell:sub(1, nShSecs * ss)
        end
    end

    -- Helper: write one sector
    local nWritten = 0
    local function ws(nRel, sData)
        tDisk.writeSector(nKblOff + nRel, B.pad(sData or "", ss))
        nWritten = nWritten + 1
    end

    -- 1. Zero-fill entire partition
    info("Zero-filling " .. nKblSize .. " sectors...")
    for i = 0, nKblSize - 1 do
        ws(i, "")
        if i % 16 == 0 then
            pcall(function() syscall("process_yield") end)
        end
    end

    -- 2. Write loader.cfg
    if sLoaderCfg and #sLoaderCfg > 0 then
        local nLcSecs = math.ceil(#sLoaderCfg / ss)
        for i = 0, math.min(nLcSecs, LAYOUT.LOADER_COUNT) - 1 do
            ws(LAYOUT.LOADER_START + i,
                sLoaderCfg:sub(i * ss + 1, (i + 1) * ss))
        end
        info(string.format("  loader.cfg: %d bytes (%d sectors)",
            #sLoaderCfg, math.min(nLcSecs, LAYOUT.LOADER_COUNT)))
    end

    -- 3. Write stage2
    for i = 0, nS2Secs - 1 do
        ws(LAYOUT.STAGE2_START + i,
            sStage2:sub(i * ss + 1, (i + 1) * ss))
        if i % 8 == 0 then
            pcall(function() syscall("process_yield") end)
        end
    end
    info(string.format("  stage2: %d bytes (%d sectors, CRC32=%08X)",
        #sStage2, nS2Secs, B.crc32(sStage2)))

    -- 4. Write shell
    if sShell and #sShell > 0 then
        for i = 0, nShSecs - 1 do
            ws(LAYOUT.SHELL_START + i,
                sShell:sub(i * ss + 1, (i + 1) * ss))
            if i % 8 == 0 then
                pcall(function() syscall("process_yield") end)
            end
        end
        info(string.format("  shell: %d bytes (%d sectors, CRC32=%08X)",
            #sShell, nShSecs, B.crc32(sShell)))
    end

    -- 5. Build KBL header
    local sHdr = "AXKB"
        .. string.char(2)       -- version 2
        .. string.char(0x12)    -- CFG_FALLBACK | CFG_AUTO_CLEAR
        -- Stage2
        .. B.u16(#sStage2)
        .. B.u32(B.crc32(sStage2))
        .. B.u16(LAYOUT.STAGE2_START)
        .. B.u16(nS2Secs)
        -- Shell
        .. B.u16(LAYOUT.SHELL_START)
        .. B.u16(nShSecs)
        .. B.u16(sShell and #sShell or 0)
        .. B.u32(sShell and #sShell > 0 and B.crc32(sShell) or 0)
        -- Loader.cfg
        .. B.u16(LAYOUT.LOADER_START)
        .. B.u16(LAYOUT.LOADER_COUNT)
        .. B.u16(sLoaderCfg and #sLoaderCfg or 0)
        -- Label
        .. B.pad("KBL", 32)
        -- Counters
        .. B.u32(0) .. B.u32(0) .. B.u32(0)
        -- Var layout
        .. B.u16(LAYOUT.VAR_START) .. B.u16(LAYOUT.VAR_COUNT)
        -- Loader CRC
        .. B.u32(sLoaderCfg and #sLoaderCfg > 0 and B.crc32(sLoaderCfg) or 0)

    sHdr = B.pad(sHdr, 96)
    local sVars = B.pad("", 144)
    sHdr = sHdr .. sVars
    sHdr = sHdr .. B.u32(B.crc32(sVars))
    sHdr = sHdr .. B.u32(B.crc32(sHdr))
    sHdr = B.pad(sHdr, 256)

    -- EEPROM offload (second half of sector 0)
    local sOffload = "AXEO"
        .. string.char(0, 0, 3, 0, 2)
        .. B.pad("", 3)
        .. B.pad("", 64)   -- machine binding
        .. B.pad("", 64)   -- kernel hash
        .. B.pad("", 64)   -- manifest hash
        .. B.pad("", 32)   -- PK fingerprint
        .. B.u32(0)         -- boot counter
        .. B.u32(0)         -- last good boot
    sOffload = sOffload .. B.u32(B.crc32(sOffload))
    sOffload = B.pad(sOffload, 256)

    ws(0, sHdr .. sOffload)

    -- 6. Verify header readback
    local sVerify = tDisk.readSector(nKblOff)
    if not sVerify or sVerify:sub(1, 4) ~= "AXKB" then
        return false, "Header verification FAILED after write"
    end

    return true, nWritten
end

-- =============================================
-- MAIN
-- =============================================

print("")
print(C_CYAN .. "═══════════════════════════════════════" .. C_RESET)
print(C_CYAN .. "  kblflash — KBL Partition Flash Tool  " .. C_RESET)
print(C_CYAN .. "═══════════════════════════════════════" .. C_RESET)
print("")

if bDryRun then
    warn("DRY RUN mode — no writes will be performed")
    print("")
end

-- 1. Find source files
info("Locating source files...")
local sStage2, sStage2Path = findFile(STAGE2_PATHS)
local sShell,  sShellPath  = findFile(SHELL_PATHS)
local sLoader              = readFile(LOADER_PATH)

if sStage2 then
    ok(string.format("stage2: %s (%d bytes)", sStage2Path, #sStage2))
else
    fail("stage2_boot.lua NOT FOUND")
    fail("Searched: " .. table.concat(STAGE2_PATHS, ", "))
    return
end

if sShell then
    ok(string.format("shell:  %s (%d bytes)", sShellPath, #sShell))
else
    warn("kbl_shell.lua not found — recovery console will be unavailable")
end

if sLoader then
    ok(string.format("loader: %s (%d bytes)", LOADER_PATH, #sLoader))
else
    warn("loader.cfg not found — default boot config will be embedded")
    sLoader = [[
return {
    timeout = 3, default = "axis",
    entries = {
        { id = "axis", title = "AxisOS v0.82-DQA", kernel = "/kernel.lua",
          init = "/bin/init.lua", params = { safemode = false, loglevel = "Info" } },
        { id = "axis-safe", title = "AxisOS (Safe Mode)", kernel = "/kernel.lua",
          init = "/bin/init.lua", params = { safemode = true, loglevel = "Debug" } },
    },
    drivers_cfg = "/boot/sys/drivers.cfg",
    secureboot = { mode = 0 },
}
]]
end

print("")

-- 2. Find drive
local tDrives = findDrives()

if #tDrives == 0 then
    fail("No drive devices found in /dev")
    fail("Make sure blkdev driver is loaded: insmod blkdev")
    return
end

if not sTargetDev then
    -- Auto-detect: find drive with RDB
    info("Scanning " .. #tDrives .. " drive(s) for RDB...")
    for _, d in ipairs(tDrives) do
        local tD, sErr = openDrive(d.path)
        if tD then
            local sH = tD.readSector(0)
            if sH and sH:sub(1, 4) == "RDSK" then
                sTargetDev = d.path
                ok("Found RDB on " .. d.path .. " (" .. fmtSz(d.capacity) .. ")")
                closeDrive()
                break
            end
            closeDrive()
        end
    end
    if not sTargetDev then
        fail("No drive with RDB partition table found")
        print("")
        print("Available drives:")
        for _, d in ipairs(tDrives) do
            print(string.format("  %-28s %s (%d sectors)",
                d.path, fmtSz(d.capacity), d.sectors))
        end
        return
    end
end

-- 3. Open drive and read RDB
info("Opening " .. sTargetDev .. "...")
local tDisk, sOpenErr = openDrive(sTargetDev)
if not tDisk then
    fail("Cannot open drive: " .. tostring(sOpenErr))
    return
end

local sRdbSec = tDisk.readSector(0)
if not sRdbSec or sRdbSec:sub(1, 4) ~= "RDSK" then
    fail("No RDB found on " .. sTargetDev)
    fail("Use xparted to initialize the partition table first")
    closeDrive()
    return
end

local tRdb = RDB.read(tDisk)
if not tRdb then
    fail("Failed to parse RDB")
    closeDrive()
    return
end

ok(string.format("RDB: %s  %d partition(s)  gen=%d",
    tRdb.label or "?", #tRdb.partitions, tRdb.generation or 0))

-- 4. Find or create KBL partition
local nKblOff, nKblSize = nil, nil

for _, p in ipairs(tRdb.partitions) do
    if p.fsType == 0x41584B42 then
        nKblOff  = p.startSector
        nKblSize = p.sizeSectors
        break
    end
end

if nKblOff then
    ok(string.format("KBL partition found at sector %d (%d sectors, %s)",
        nKblOff, nKblSize, fmtSz(nKblSize * tDisk.sectorSize)))

    -- Show current KBL status
    local sKblHdr = tDisk.readSector(nKblOff)
    if sKblHdr and sKblHdr:sub(1, 4) == "AXKB" then
        local nVer = sKblHdr:byte(5) or 0
        local nS2Size = B.r16(sKblHdr, 7)
        local nS2Crc  = B.r32(sKblHdr, 9)
        info(string.format("  Current: v%d, stage2=%d bytes (CRC=%08X)",
            nVer, nS2Size, nS2Crc))
    else
        info("  Current: uninitialized (no AXKB header)")
    end
else
    warn("KBL partition NOT found — creating one...")
    print("")

    if bDryRun then
        info("DRY RUN: Would create KBL partition (" .. KBL_DEFAULT_SIZE .. " sectors)")
    else
        local tNewPart, sCreateErr = createKblPartition(tDisk, tRdb)
        if not tNewPart then
            fail("Cannot create KBL partition: " .. tostring(sCreateErr))
            closeDrive()
            return
        end
        nKblOff  = tNewPart.startSector
        nKblSize = tNewPart.sizeSectors
        ok(string.format("KBL partition created at sector %d (%d sectors)",
            nKblOff, nKblSize))
        -- Re-read RDB
        tRdb = RDB.read(tDisk)
    end
end

if nKblSize and nKblSize < KBL_MIN_SECTORS then
    warn(string.format("KBL partition is small (%d sectors < %d recommended)",
        nKblSize, KBL_MIN_SECTORS))
end

print("")

-- 5. Show summary and confirm
print(C_CYAN .. "═══ Flash Plan ═══" .. C_RESET)
print(string.format("  Drive:      %s", sTargetDev))
print(string.format("  KBL:        sector %d, %d sectors (%s)",
    nKblOff or 0, nKblSize or 0,
    fmtSz((nKblSize or 0) * tDisk.sectorSize)))
print(string.format("  Stage2:     %d bytes → sectors %d-%d",
    #sStage2, LAYOUT.STAGE2_START,
    LAYOUT.STAGE2_START + math.ceil(#sStage2 / tDisk.sectorSize) - 1))
if sShell then
    print(string.format("  Shell:      %d bytes → sectors %d-%d",
        #sShell, LAYOUT.SHELL_START,
        LAYOUT.SHELL_START + math.ceil(#sShell / tDisk.sectorSize) - 1))
end
print(string.format("  Loader.cfg: %d bytes → sectors %d-%d",
    #sLoader, LAYOUT.LOADER_START, LAYOUT.LOADER_START + LAYOUT.LOADER_COUNT - 1))
print("")

if bDryRun then
    ok("DRY RUN complete — no changes written")
    closeDrive()
    return
end

if not bForce then
    io.write(C_YELLOW .. "Write KBL data? This overwrites the entire KBL partition. [y/N] " .. C_RESET)
    local sAnswer = io.read()
    if not sAnswer or (sAnswer:lower() ~= "y" and sAnswer:lower() ~= "yes") then
        info("Aborted.")
        closeDrive()
        return
    end
end

-- 6. Flash!
print("")
info("Flashing KBL partition...")

local bFlashOk, vResult = flashKbl(tDisk, nKblOff, nKblSize,
    sStage2, sShell, sLoader)

if bFlashOk then
    print("")
    ok("╔═══════════════════════════════════╗")
    ok("║   KBL FLASH COMPLETE              ║")
    ok("╚═══════════════════════════════════╝")
    ok(string.format("  %d sectors written", vResult))
    ok(string.format("  Stage2: %d bytes (CRC32=%08X)", #sStage2, B.crc32(sStage2)))
    if sShell then
        ok(string.format("  Shell:  %d bytes (CRC32=%08X)", #sShell, B.crc32(sShell)))
    end
    ok(string.format("  Loader: %d bytes", #sLoader))
    print("")

    -- Verify by re-reading
    local sCheck = tDisk.readSector(nKblOff)
    if sCheck and sCheck:sub(1, 4) == "AXKB" then
        local nChkS2 = B.r16(sCheck, 7)
        local nChkCrc = B.r32(sCheck, 9)
        if nChkS2 == #sStage2 and nChkCrc == B.crc32(sStage2) then
            ok("Verification: PASSED (header + CRC match)")
        else
            warn("Verification: size/CRC mismatch in readback!")
        end
    else
        warn("Verification: header readback failed")
    end
else
    fail("Flash FAILED: " .. tostring(vResult))
end

closeDrive()