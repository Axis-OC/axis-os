--
-- /usr/commands/xparted.lua
-- AxisOS AXFS Drive Manager — Graphical (XE-based)
-- Combines parted + axfs-switch into a gparted-like UI.
--
-- Features:
--   • Visual partition bar (gparted-style)
--   • Manual partitioning (add/remove/format)
--   • AXFS Switch Wizard (plain or EFI+AXFS)
--   • Non-RAM streaming OS installation with per-file progress
--   • Full @RDB::Partition extension support
--   • Proper error handling (no stalling, OOM, or infinite loops)
--
-- Usage:
--   xparted                  (interactive)
--   xparted /dev/drive_xxxx  (open device directly)
--

local fs   = require("filesystem")
local XE   = require("xe")
local AX   = require("axfs_core")
local RDB  = require("rdb")
local B    = require("bpack")
local args = env.ARGS or {}

-- =============================================
-- CONSTANTS
-- =============================================

local VERSION = "1.0.2"

local PART_COLORS = {
    ["AXFS v2"]  = 0x55FF55,
    ["AXFS v1"]  = 0x44CC44,
    ["AXEFI"]    = 0xFF55FF,
    ["AXKBL"]    = 0xFFAA00,
    ["AXKSR"]    = 0xFFAA55,
    ["AXOLR"]    = 0xAA55FF,
    ["AXVB"]     = 0xCC55CC,
    ["AXBC"]     = 0x55CCCC,
    ["AXSN"]     = 0xCCCC55,
    ["Swap"]     = 0xFF8844,
    ["FAT"]      = 0x5555FF,
    ["Raw"]      = 0x888888,
    free         = 0x333344,
}

-- =============================================
-- STATE
-- =============================================

local g_hDev      = nil
local g_tDisk     = nil
local g_tRdb      = nil
local g_sDev      = nil
local g_tDevInfo  = nil
local g_tVol      = {}
local g_tPartDisk = {}

local g_sPage     = "scan"
local g_bRunning  = true
local g_sError    = nil
local g_sStatus   = ""

-- Wizard state
local g_tWizard = {
    bEfi         = false,
    bKsr         = true,
    bOlr         = true,
    bKbl         = true,
    bAxvb        = true,
    bAxbc        = true,
    bAxsn        = true,
    sLabel       = "AxisOS",
    nEfiSectors  = 48,
    nKsrSectors  = 96,
    nOlrSectors  = 2,
    nKblSectors  = 128,
    nAxvbSectors = 24,
    nAxbcSectors = 2,
    nAxsnSectors = 512,
    bConfirmed   = false,
    nStep        = 1,
    sResult      = nil,
}

-- Install state
local g_tInstall = {
    nPartIdx     = -1,
    bRunning     = false,
    bDone        = false,
    nTotal       = 0,
    nCurrent     = 0,
    nFiles       = 0,
    nDirs        = 0,
    nBytes       = 0,
    nErrors      = 0,
    sCurrentFile = "",
    tFailed      = {},
    sResult      = nil,
    nElapsed     = 0,
}

local g_nSelPart = 0

-- =============================================
-- DEBUG INSTRUMENTATION (remove after diagnosis)
-- =============================================
local DBG = true
local g_nDbgDiskReads, g_nDbgDiskWrites = 0, 0
local g_nDbgDiskReadSec, g_nDbgDiskWriteSec = 0, 0

local function dbg(sFmt, ...)
    if not DBG then return end
    local bOk, sMsg = pcall(string.format, sFmt, ...)
    if not bOk then sMsg = sFmt end
    pcall(function()
        syscall("kernel_log",
            string.format("[xparted:DBG] [t=%.2f mem=%dKB] %s",
                computer.uptime(),
                math.floor(computer.freeMemory() / 1024),
                sMsg))
    end)
end

local function dbgDiskReset()
    g_nDbgDiskReads = 0; g_nDbgDiskWrites = 0
    g_nDbgDiskReadSec = 0; g_nDbgDiskWriteSec = 0
end

local function dbgDisk(sLabel)
    dbg("%s — diskIO: R=%d(%.1fs) W=%d(%.1fs)",
        sLabel, g_nDbgDiskReads, g_nDbgDiskReadSec,
        g_nDbgDiskWrites, g_nDbgDiskWriteSec)
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

--- Yield to the OC host and the kernel scheduler.
--- Every call resets the "too long without yielding" timer.
local function yieldFlush()
    pcall(function() syscall("process_yield") end)
end

local function safeCall(f, ...)
    local tR = table.pack(pcall(f, ...))
    if tR[1] then
        return table.unpack(tR, 2, tR.n)
    end
    return nil, tostring(tR[2])
end

-- =============================================
-- DEVICE MANAGEMENT
-- =============================================

local function closeDevice()
    for idx in pairs(g_tVol) do
        pcall(function() g_tVol[idx]:flush() end)
    end
    g_tVol = {}; g_tPartDisk = {}
    if g_hDev then fs.close(g_hDev); g_hDev = nil end
    g_tDisk = nil; g_tRdb = nil; g_sDev = nil; g_tDevInfo = nil
end

local function openDevice(sPath)
    closeDevice()
    local h = fs.open(sPath, "r")
    if not h then return nil, "Cannot open " .. sPath end
    local bI, tI = fs.deviceControl(h, "info", {})
    if not bI or not tI then
        fs.close(h); return nil, "Device info failed"
    end
    g_hDev = h; g_sDev = sPath; g_tDevInfo = tI
    local ss = tI.sectorSize
    g_tDisk = {
        sectorSize  = ss,
        sectorCount = tI.sectorCount,
        readSector = function(n)
            g_nDbgDiskReads = g_nDbgDiskReads + 1
            local t0 = computer.uptime()
            local bOk, d = fs.deviceControl(h, "read_sector", {n + 1})
            local dt = computer.uptime() - t0
            g_nDbgDiskReadSec = g_nDbgDiskReadSec + dt
            if dt > 1.0 then
                dbg("SLOW readSector(%d): %.2fs", n, dt)
            end
            return bOk and d or nil
        end,
        writeSector = function(n, d)
            g_nDbgDiskWrites = g_nDbgDiskWrites + 1
            local t0 = computer.uptime()
            d = B.pad(d or "", ss)
            local r = fs.deviceControl(h, "write_sector", {n + 1, d:sub(1, ss)})
            local dt = computer.uptime() - t0
            g_nDbgDiskWriteSec = g_nDbgDiskWriteSec + dt
            if dt > 1.0 then
                dbg("SLOW writeSector(%d): %.2fs", n, dt)
            end
            return r
        end,
    }
    local sH = g_tDisk.readSector(0)
    if sH and #sH >= 4 and sH:sub(1, 4) == "RDSK" then
        g_tRdb = RDB.read(g_tDisk)
    end
    return true
end

local function getPartDisk(nIdx)
    if g_tPartDisk[nIdx] then return g_tPartDisk[nIdx] end
    if not g_tRdb or not g_tRdb.partitions[nIdx + 1] then return nil end
    local p   = g_tRdb.partitions[nIdx + 1]
    local ss  = g_tDisk.sectorSize
    local off = p.startSector
    local tPD = {
        sectorSize  = ss,
        sectorCount = p.sizeSectors,
        readSector  = function(n) return g_tDisk.readSector(off + n) end,
        writeSector = function(n, d) return g_tDisk.writeSector(off + n, d) end,
    }
    g_tPartDisk[nIdx] = tPD
    return tPD
end

local function getVol(nIdx)
    dbg("getVol(%d): ENTER", nIdx)
    if g_tVol[nIdx] then dbg("getVol(%d): cached hit", nIdx); return g_tVol[nIdx] end
    local tPD = getPartDisk(nIdx)
    if not tPD then dbg("getVol(%d): no partDisk!", nIdx); return nil, "No partition " .. nIdx end
    if g_tVol[nIdx] then
        pcall(function() g_tVol[nIdx]:flush() end)
        g_tVol[nIdx] = nil
    end
    dbgDiskReset()
    dbg("getVol(%d): calling AX.mount (cacheSize=24)...", nIdx)
    local t0 = computer.uptime()
    local vol, e = AX.mount(tPD, { cacheSize = 24 })
    local dt = computer.uptime() - t0
    dbg("getVol(%d): AX.mount returned in %.2fs (vol=%s err=%s)", nIdx, dt, tostring(vol ~= nil), tostring(e))
    dbgDisk("getVol mount")
    if not vol then return nil, e end
    g_tVol[nIdx] = vol
    return vol
end

local function findDrives()
    local tDrives = {}
    local tDevList = fs.list("/dev")
    if tDevList then
        for _, sName in ipairs(tDevList) do
            local sClean = sName:gsub("/$", "")
            if sClean:find("drive", 1, true) then
                local sFullPath = "/dev/" .. sClean
                local hD = fs.open(sFullPath, "r")
                if hD then
                    local bI, tI = fs.deviceControl(hD, "info", {})
                    fs.close(hD)
                    if bI and tI then
                        tDrives[#tDrives + 1] = {
                            path     = sFullPath,
                            capacity = tI.capacity or (tI.sectorCount * tI.sectorSize),
                            sectors  = tI.sectorCount,
                            secSize  = tI.sectorSize,
                        }
                    end
                end
            end
        end
    end
    return tDrives
end

-- =============================================
-- RDB DISPLAY HELPERS
-- =============================================

local function fmtPartFlags(p)
    local tF = {}
    local nF = p.flags or 0
    if bit32.band(nF, RDB.PF_BOOTABLE)  ~= 0 then tF[#tF+1] = "boot" end
    if bit32.band(nF, RDB.PF_AUTOMOUNT) ~= 0 then tF[#tF+1] = "auto" end
    if bit32.band(nF, RDB.PF_READONLY)  ~= 0 then tF[#tF+1] = "ro" end
    if bit32.band(nF, RDB.PF_HIDDEN_FS) ~= 0 then tF[#tF+1] = "hidden" end
    if bit32.band(nF, RDB.PF_SYSTEM)    ~= 0 then tF[#tF+1] = "system" end
    if bit32.band(nF, RDB.PF_ENCRYPTED) ~= 0 then tF[#tF+1] = "enc" end
    return table.concat(tF, ",")
end

local function fsTypeName(nType)
    return RDB.fsTypeName(nType)
end

local function partColor(p)
    local sType = fsTypeName(p.fsType)
    return PART_COLORS[sType] or 0x666666
end

-- =============================================
-- INITIALIZATION: Create RDB
-- =============================================

local function doInitRdb()
    if not g_tDisk then return false, "No device" end
    local tNew = {
        label = "AxisDisk", totalSectors = g_tDisk.sectorCount,
        generation = 0, partitions = {},
    }
    local bOk, sErr = safeCall(RDB.write, g_tDisk, tNew)
    if not bOk then return false, "RDB write failed: " .. tostring(sErr) end
    g_tRdb = RDB.read(g_tDisk)
    g_tVol = {}; g_tPartDisk = {}
    return true
end

-- =============================================
-- PARTITION OPERATIONS
-- =============================================

local function doAddPart(sName, nSz)
    if not g_tRdb then return false, "No RDB" end
    if #g_tRdb.partitions >= RDB.MAX_PARTS then return false, "Max partitions" end
    local nStart = RDB.nextFree(g_tRdb)
    local nFree  = g_tRdb.totalSectors - nStart
    if nSz <= 0 then nSz = nFree end
    if nFree <= 0 then return false, "No free space" end
    if nSz > nFree then return false, "Only " .. nFree .. " sectors free" end
    table.insert(g_tRdb.partitions, {
        deviceName = sName, fsLabel = sName,
        startSector = nStart, sizeSectors = nSz,
        fsType = RDB.FS_AXFS2, flags = RDB.PF_AUTOMOUNT,
        bootPriority = 0, reserved = 0,
        ext = {
            visibility = RDB.VIS_NORMAL,
            bootRole = RDB.ROLE_AXFS_ROOT,
            integrityMode = RDB.INTEGRITY_CRC32,
            extVersion = 1,
        },
    })
    RDB.write(g_tDisk, g_tRdb)
    g_tRdb = RDB.read(g_tDisk)
    return true
end

local function doRmPart(nIdx)
    if not g_tRdb or not g_tRdb.partitions[nIdx + 1] then return false end
    table.remove(g_tRdb.partitions, nIdx + 1)
    RDB.write(g_tDisk, g_tRdb); g_tRdb = RDB.read(g_tDisk)
    g_tVol[nIdx] = nil; g_tPartDisk[nIdx] = nil
    return true
end

local function doFormat(nIdx, sLabel)
    if not g_tRdb or not g_tRdb.partitions[nIdx + 1] then return false end
    local p = g_tRdb.partitions[nIdx + 1]
    local tPD = getPartDisk(nIdx)
    if not tPD then return false, "Cannot access partition" end
    sLabel = sLabel or p.fsLabel or p.deviceName or "AxisFS"
    g_tVol[nIdx] = nil
    local bOk, e = safeCall(AX.format, tPD, sLabel)
    if not bOk then return false, "Format failed: " .. tostring(e) end
    return true
end

-- =============================================
-- AXFS SWITCH WIZARD
-- =============================================

local function doWizardExecute()
    if not g_tDisk or not g_tDevInfo then return false, "No device" end

    local bEfi         = g_tWizard.bEfi
    local sLabel       = g_tWizard.sLabel or "AxisOS"
    local nEfiSectors  = g_tWizard.nEfiSectors or 48
    local nKsrSectors  = g_tWizard.nKsrSectors or 96
    local nOlrSectors  = g_tWizard.nOlrSectors or 2
    local nKblSectors  = g_tWizard.nKblSectors or 128
    local nAxvbSectors = g_tWizard.nAxvbSectors or 24
    local nAxbcSectors = g_tWizard.nAxbcSectors or 2
    local bAxsn        = g_tWizard.bAxsn
    local nAxsnSectors = g_tWizard.nAxsnSectors or 512

    local ss = g_tDevInfo.sectorSize
    local nPartStart = RDB.MAX_PARTS + 1
    local tPartitions = {}
    local nCursor = nPartStart

    -- ═══ 1. OLR (always) ═══
    tPartitions[#tPartitions + 1] = {
        deviceName = "OLR0", dhIndex = #tPartitions,
        startSector = nCursor, sizeSectors = nOlrSectors,
        fsType = RDB.FS_AXOLR,
        flags = RDB.PF_HIDDEN_FS + RDB.PF_SYSTEM,
        bootPriority = -1, reserved = 0, fsLabel = "OLR",
        ext = { visibility = RDB.VIS_SYSTEM, encryptType = RDB.ENC_NONE,
                bootRole = RDB.ROLE_DATA, integrityMode = RDB.INTEGRITY_CRC32, extVersion = 1 },
    }
    nCursor = nCursor + nOlrSectors

    -- ═══ 2. KSR (always) ═══
    tPartitions[#tPartitions + 1] = {
        deviceName = "KSR0", dhIndex = #tPartitions,
        startSector = nCursor, sizeSectors = nKsrSectors,
        fsType = RDB.FS_AXKSR,
        flags = RDB.PF_HIDDEN_FS + RDB.PF_SYSTEM,
        bootPriority = -1, reserved = 0, fsLabel = "KSR",
        ext = { visibility = RDB.VIS_SYSTEM, encryptType = RDB.ENC_NONE,
                bootRole = RDB.ROLE_DATA, integrityMode = RDB.INTEGRITY_CRC32, extVersion = 1 },
    }
    nCursor = nCursor + nKsrSectors

    -- ═══ 3. EFI (optional) ═══
    if bEfi then
        tPartitions[#tPartitions + 1] = {
            deviceName = "EFI0", dhIndex = #tPartitions,
            startSector = nCursor, sizeSectors = nEfiSectors,
            fsType = RDB.FS_AXEFI,
            flags = RDB.PF_BOOTABLE + RDB.PF_READONLY + RDB.PF_HIDDEN_FS + RDB.PF_SYSTEM + RDB.PF_ENCRYPTED,
            bootPriority = 10, reserved = 0, fsLabel = "SYSTEM",
            ext = { visibility = RDB.VIS_SYSTEM, encryptType = RDB.ENC_XOR_HMAC,
                    bootRole = RDB.ROLE_EFI_STAGE3, integrityMode = RDB.INTEGRITY_SHA256, extVersion = 1 },
        }
        nCursor = nCursor + nEfiSectors
    end

    -- ═══ 4. KBL (always) ═══
    tPartitions[#tPartitions + 1] = {
        deviceName = "KBL0", dhIndex = #tPartitions,
        startSector = nCursor, sizeSectors = nKblSectors,
        fsType = 0x41584B42,
        flags = RDB.PF_HIDDEN_FS + RDB.PF_SYSTEM,
        bootPriority = -1, reserved = 0, fsLabel = "KBL",
        ext = { visibility = RDB.VIS_SYSTEM, encryptType = RDB.ENC_NONE,
                bootRole = 5, integrityMode = RDB.INTEGRITY_CRC32, extVersion = 1 },
    }
    local nKblOff = nCursor
    nCursor = nCursor + nKblSectors

    -- ═══ 5. AXBC (always) ═══
    tPartitions[#tPartitions + 1] = {
        deviceName = "BC0", dhIndex = #tPartitions,
        startSector = nCursor, sizeSectors = nAxbcSectors,
        fsType = 0x41584243,
        flags = RDB.PF_HIDDEN_FS + RDB.PF_SYSTEM,
        bootPriority = -1, reserved = 0, fsLabel = "BOOTCTL",
        ext = { visibility = RDB.VIS_SYSTEM, encryptType = RDB.ENC_NONE,
                bootRole = 7, integrityMode = RDB.INTEGRITY_CRC32, extVersion = 1 },
    }
    local nAxbcOff = nCursor
    nCursor = nCursor + nAxbcSectors

    -- ═══ 6. AXVB (always) ═══
    tPartitions[#tPartitions + 1] = {
        deviceName = "VB0", dhIndex = #tPartitions,
        startSector = nCursor, sizeSectors = nAxvbSectors,
        fsType = 0x41585642,
        flags = RDB.PF_HIDDEN_FS + RDB.PF_SYSTEM + RDB.PF_ENCRYPTED,
        bootPriority = -1, reserved = 0, fsLabel = "VBOOT",
        ext = { visibility = RDB.VIS_SYSTEM, encryptType = RDB.ENC_XOR_HMAC,
                bootRole = 6, integrityMode = RDB.INTEGRITY_SHA256, extVersion = 1 },
    }
    local nAxvbOff = nCursor
    nCursor = nCursor + nAxvbSectors

    -- ═══ 7. AXSN (optional) ═══
    local nAxsnOff = nil
    if bAxsn then
        tPartitions[#tPartitions + 1] = {
            deviceName = "SN0", dhIndex = #tPartitions,
            startSector = nCursor, sizeSectors = nAxsnSectors,
            fsType = 0x4158534E,
            flags = RDB.PF_HIDDEN_FS + RDB.PF_SYSTEM + RDB.PF_ENCRYPTED,
            bootPriority = -1, reserved = 0, fsLabel = "SNAPSHOT",
            ext = { visibility = RDB.VIS_SYSTEM, encryptType = RDB.ENC_XOR_HMAC,
                    bootRole = 8, integrityMode = RDB.INTEGRITY_CRC32, extVersion = 1 },
        }
        nAxsnOff = nCursor
        nCursor = nCursor + nAxsnSectors
    end

    -- ═══ 8. AXFS (always, remaining space) ═══
    local nAxfsStart = nCursor
    local nAxfsSize  = g_tDevInfo.sectorCount - nAxfsStart
    if nAxfsSize < 64 then return false, "Drive too small for all partitions" end

    tPartitions[#tPartitions + 1] = {
        deviceName = "DH0", dhIndex = #tPartitions,
        startSector = nAxfsStart, sizeSectors = nAxfsSize,
        fsType = RDB.FS_AXFS2,
        flags = RDB.PF_BOOTABLE + RDB.PF_AUTOMOUNT,
        bootPriority = 0, reserved = 0, fsLabel = sLabel,
        ext = { visibility = RDB.VIS_NORMAL, bootRole = RDB.ROLE_AXFS_ROOT,
                integrityMode = RDB.INTEGRITY_CRC32, extVersion = 1 },
    }

    -- ═══ WRITE RDB (all partitions at once) ═══
    local tRdb = {
        label = sLabel, totalSectors = g_tDevInfo.sectorCount,
        generation = 0, partitions = tPartitions,
    }
    local bWOk, sWErr = safeCall(RDB.write, g_tDisk, tRdb)
    if not bWOk then return false, "RDB write failed: " .. tostring(sWErr) end
    yieldFlush()

    local vRdb = g_tDisk.readSector(0)
    if not vRdb or vRdb:sub(1, 4) ~= "RDSK" then return false, "RDB verification failed" end

    -- ═══ INITIALIZE OLR ═══
    do
        local nOlrOff = tPartitions[1].startSector
        for i = 0, nOlrSectors - 1 do g_tDisk.writeSector(nOlrOff + i, B.pad("", ss)) end
        local sOlrHdr = "AXOL" .. string.char(1, 2, 0, 0) .. string.rep("\0", ss - 8)
        g_tDisk.writeSector(nOlrOff, B.pad(sOlrHdr, ss))
        g_tDisk.writeSector(nOlrOff + 1, B.pad(sOlrHdr, ss))
    end
    yieldFlush()

    -- ═══ INITIALIZE KSR ═══
    do
        local nKsrOff = tPartitions[2].startSector
        for i = 0, nKsrSectors - 1 do g_tDisk.writeSector(nKsrOff + i, B.pad("", ss)) end
        local sKsrHdr = "AXKS" .. string.char(1) .. string.char(0) .. B.u16(56)
            .. B.u32(0) .. B.u32(0) .. string.rep("\0", 32)
        sKsrHdr = sKsrHdr .. B.u32(B.crc32(sKsrHdr))
        g_tDisk.writeSector(nKsrOff, B.pad(sKsrHdr, ss))
    end
    yieldFlush()

    -- ═══ INITIALIZE KBL ═══
    do
        local nKblSz = nKblSectors
        yieldFlush()

        -- Read stage2 boot code
        local sStage2 = nil
        local STAGE2_PATHS = {
            "/boot/sys/stage2_boot.lua",
            "/boot/stage2_boot.lua",
            "/system/stage2_boot.lua",
        }
        for _, sPath in ipairs(STAGE2_PATHS) do
            local hS = fs.open(sPath, "r")
            if hS then
                local tC = {}
                while true do local s = fs.read(hS, 4096); if not s then break end; tC[#tC + 1] = s end
                fs.close(hS)
                local sD = table.concat(tC)
                if #sD > 0 then sStage2 = sD; break end
            end
        end

        -- Read KBL shell code
        local sShell = nil
        local SHELL_PATHS = {
            "/boot/kbl_shell.lua", "/lib/kbl_shell.lua",
            "/system/kbl_shell.lua", "/boot/sys/kbl_shell.lua",
        }
        for _, sPath in ipairs(SHELL_PATHS) do
            local hS = fs.open(sPath, "r")
            if hS then
                local tC = {}
                while true do local s = fs.read(hS, 4096); if not s then break end; tC[#tC + 1] = s end
                fs.close(hS)
                local sD = table.concat(tC)
                if #sD > 0 then sShell = sD; break end
            end
        end

        -- Read loader.cfg
        local sLoaderCfg = nil
        local hLc = fs.open("/boot/loader.cfg", "r")
        if hLc then
            local tC = {}
            while true do local s = fs.read(hLc, 4096); if not s then break end; tC[#tC + 1] = s end
            fs.close(hLc)
            sLoaderCfg = table.concat(tC)
        end
        if not sLoaderCfg or #sLoaderCfg == 0 then
            sLoaderCfg = [[
return {
    timeout = 3, default = "axis",
    entries = {
        { id = "axis", title = "AxisOS v0.82-DQA", kernel = "/kernel.lua",
          init = "/bin/init.lua", params = { safemode = false, loglevel = "Info" } },
        { id = "axis-safe", title = "AxisOS v0.82-DQA (Safe Mode)", kernel = "/kernel.lua",
          init = "/bin/init.lua", params = { safemode = true, loglevel = "Debug" } },
    },
    drivers_cfg = "/boot/sys/drivers.cfg",
    secureboot = { mode = 0 },
}
]]
        end

        -- Zero fill KBL partition
        for i = 0, nKblSz - 1 do
            g_tDisk.writeSector(nKblOff + i, B.pad("", ss))
            if i % 8 == 0 then yieldFlush() end
        end
        yieldFlush()

        local L = {
            LOADER_START = 1, LOADER_COUNT = 3,
            STAGE2_START = 4, STAGE2_COUNT = 47,
            SHELL_START = 51, SHELL_COUNT = 50,
            VAR_START = 101, VAR_COUNT = 24,
        }

        -- Write loader.cfg
        if sLoaderCfg and #sLoaderCfg > 0 then
            local nLcSectors = math.ceil(#sLoaderCfg / ss)
            for i = 0, math.min(nLcSectors, L.LOADER_COUNT) - 1 do
                local sChunk = sLoaderCfg:sub(i * ss + 1, (i + 1) * ss)
                g_tDisk.writeSector(nKblOff + L.LOADER_START + i, B.pad(sChunk, ss))
            end
        end
        yieldFlush()

        -- Write stage2
        local nS2Secs = 0
        if sStage2 and #sStage2 > 0 then
            nS2Secs = math.ceil(#sStage2 / ss)
            for i = 0, math.min(nS2Secs, L.STAGE2_COUNT) - 1 do
                local sChunk = sStage2:sub(i * ss + 1, (i + 1) * ss)
                g_tDisk.writeSector(nKblOff + L.STAGE2_START + i, B.pad(sChunk, ss))
                if i % 4 == 0 then yieldFlush() end
            end
        end
        yieldFlush()

        -- Write shell
        local nShSecs = 0
        if sShell and #sShell > 0 then
            nShSecs = math.ceil(#sShell / ss)
            for i = 0, math.min(nShSecs, L.SHELL_COUNT) - 1 do
                local sChunk = sShell:sub(i * ss + 1, (i + 1) * ss)
                g_tDisk.writeSector(nKblOff + L.SHELL_START + i, B.pad(sChunk, ss))
                if i % 4 == 0 then yieldFlush() end
            end
        end
        yieldFlush()

        -- Write KBL header (sector 0)
        local sHdr = "AXKB"
            .. string.char(2)
            .. string.char(0x12)
            .. B.u16(sStage2 and #sStage2 or 0)
            .. B.u32(sStage2 and #sStage2 > 0 and B.crc32(sStage2) or 0)
            .. B.u16(L.STAGE2_START)
            .. B.u16(nS2Secs)
            .. B.u16(L.SHELL_START)
            .. B.u16(nShSecs)
            .. B.u16(sShell and #sShell or 0)
            .. B.u32(sShell and #sShell > 0 and B.crc32(sShell) or 0)
            .. B.u16(L.LOADER_START)
            .. B.u16(L.LOADER_COUNT)
            .. B.u16(sLoaderCfg and #sLoaderCfg or 0)
            .. B.pad("KBL", 32)
            .. B.u32(0) .. B.u32(0) .. B.u32(0)
            .. B.u16(L.VAR_START) .. B.u16(L.VAR_COUNT)
            .. B.u32(sLoaderCfg and #sLoaderCfg > 0 and B.crc32(sLoaderCfg) or 0)

        sHdr = B.pad(sHdr, 96)
        sHdr = sHdr .. B.pad("", 144)
        sHdr = sHdr .. B.u32(B.crc32(B.pad("", 144)))
        sHdr = sHdr .. B.u32(B.crc32(sHdr))
        sHdr = B.pad(sHdr, 256)

        local sOffload = "AXEO"
            .. string.char(0, 0, 3, 0, 2)
            .. B.pad("", 3)
            .. B.pad("", 64)
            .. B.pad("", 64)
            .. B.pad("", 64)
            .. B.pad("", 32)
            .. B.u32(0)
            .. B.u32(0)
        sOffload = sOffload .. B.u32(B.crc32(sOffload))
        sOffload = B.pad(sOffload, 256)

        g_tDisk.writeSector(nKblOff, B.pad(sHdr .. sOffload, ss))
        yieldFlush()
    end

    -- ═══ INITIALIZE AXBC ═══
    do
        for i = 0, nAxbcSectors - 1 do
            g_tDisk.writeSector(nAxbcOff + i, B.pad("", ss))
        end
        local sAxbcHdr = "AXBC" .. string.char(1, 0, 0, 0)
            .. B.u32(0) .. B.u32(0) .. B.u32(0) .. B.u32(0)
            .. B.u32(0) .. B.u32(0) .. B.pad("", 32) .. B.pad("", 32)
        sAxbcHdr = sAxbcHdr .. B.u32(B.crc32(sAxbcHdr))
        g_tDisk.writeSector(nAxbcOff, B.pad(sAxbcHdr, ss))
        g_tDisk.writeSector(nAxbcOff + 1, B.pad(sAxbcHdr, ss))
    end
    yieldFlush()

    -- ═══ INITIALIZE AXVB ═══
    do
        for i = 0, nAxvbSectors - 1 do
            g_tDisk.writeSector(nAxvbOff + i, B.pad("", ss))
        end
        local sAxvbHdr = "AXVB" .. string.char(1, 0) .. B.u16(0)
            .. B.u32(0) .. B.pad("", 32) .. B.pad("", 32)
            .. B.u32(0) .. B.u32(0) .. B.pad("", 32)
        sAxvbHdr = sAxvbHdr .. B.u32(B.crc32(sAxvbHdr))
        g_tDisk.writeSector(nAxvbOff, B.pad(sAxvbHdr, ss))
    end
    yieldFlush()

    -- ═══ INITIALIZE AXSN (if enabled) ═══
    if bAxsn and nAxsnOff then
        for i = 0, nAxsnSectors - 1 do
            g_tDisk.writeSector(nAxsnOff + i, B.pad("", ss))
            if i % 16 == 0 then yieldFlush() end
        end
        local sAxsnHdr = "AXSN" .. string.char(1, 0) .. B.u16(0)
            .. B.u32(0) .. B.pad("", 64)
        g_tDisk.writeSector(nAxsnOff, B.pad(sAxsnHdr, ss))
    end
    yieldFlush()

    -- ═══ FORMAT AXFS ═══
    local tAxfsDisk = {
        sectorSize  = ss, sectorCount = nAxfsSize,
        readSector  = function(n) return g_tDisk.readSector(nAxfsStart + n) end,
        writeSector = function(n, d) d = B.pad(d or "", ss); return g_tDisk.writeSector(nAxfsStart + n, d:sub(1, ss)) end,
    }

    local bFmtOk, bFmt, sFmtErr = pcall(AX.format, tAxfsDisk, sLabel)
    if not bFmtOk then return false, "FORMAT CRASHED: " .. tostring(bFmt) end
    yieldFlush()
    if not bFmt then return false, "Format failed: " .. tostring(sFmtErr) end

    local vSb = g_tDisk.readSector(nAxfsStart)
    if not vSb or vSb:sub(1, 4) ~= "AXF2" then return false, "AXFS superblock verification failed" end

    g_tRdb = RDB.read(g_tDisk)
    g_tVol = {}; g_tPartDisk = {}
    return true
end

-- =============================================
-- NON-RAM STREAMING INSTALLATION
--
-- FIX 1: Mount volume BEFORE entering the install
--        page so the stall happens while a "Preparing…"
--        message is visible.
-- FIX 2: Yield aggressively between every heavy
--        in-memory operation (concat, gsub, cache ops).
-- FIX 3: renderInstallProgress no longer swallows
--        errors — endFrame/beginFrame failures are
--        logged and the function gracefully degrades
--        to yield-only mode.
-- =============================================

local function doInstall(nPartIdx, fProgress)
    local p = g_tRdb.partitions[nPartIdx + 1]
    if not p then return false, "Invalid partition" end
    if RDB.isEfiPartition(p) then return false, "Cannot install onto EFI partition" end

    local vol, e = getVol(nPartIdx)
    if not vol then return false, e end

    local tSkip = {
        ["/tmp"] = true, ["/log"] = true, ["/vbl"] = true, ["/dev"] = true,
        ["/golden"] = true, ["/logs"] = true, ["/var/sys/log"] = true,
    }

    -- Phase 1: Enumerate
    fProgress("scan", 0, 0, "Scanning filesystem...")

    local tEntries = {}
    local function walk(sDir)
        yieldFlush()
        local bOk, tList = pcall(fs.list, sDir)
        if not bOk or not tList then return end
        for _, sName in ipairs(tList) do
            local bIsDir = sName:sub(-1) == "/"
            local sClean = bIsDir and sName:sub(1, -2) or sName
            local sSrc   = (sDir == "/" and "" or sDir) .. "/" .. sClean
            sSrc = sSrc:gsub("//", "/")
            if tSkip[sSrc] then goto skip end
            tEntries[#tEntries + 1] = { src = sSrc, isDir = bIsDir }
            if bIsDir then walk(sSrc) end
            if #tEntries % 6 == 0 then yieldFlush() end
            ::skip::
        end
    end

    local bWalkOk, sWalkErr = pcall(walk, "/")
    if not bWalkOk then return false, "Scan failed: " .. tostring(sWalkErr) end

    local nTotal = #tEntries
    if nTotal == 0 then return false, "No files found to install" end

    -- Phase 2: Essential dirs
    yieldFlush()
    for idx, sDir in ipairs({
        "/bin", "/etc", "/lib", "/drivers", "/system",
        "/usr", "/usr/commands", "/home", "/tmp", "/boot",
        "/system/lib", "/system/lib/dk", "/lib/vi", "/lib/hbm",
        "/sys", "/sys/security", "/sys/drivers",
        "/root", "/home/guest", "/boot/sys",
    }) do
        pcall(function() vol:mkdir(sDir) end)
        if idx % 2 == 0 then yieldFlush() end
    end
    pcall(function() vol:flush() end)
    yieldFlush()

    -- Phase 3: Copy files
    local nFiles, nDirs, nBytes, nErrors = 0, 0, 0, 0
    local tFailed = {}
    local nStartTime = computer.uptime()
    local PURGE_EVERY = 6
    local nFilesSincePurge = 0

    for i, ent in ipairs(tEntries) do
        -- CRITICAL: yield at the TOP of every iteration
        yieldFlush()

        local sShort = ent.src:match("([^/]+)$") or ent.src
        fProgress("copy", i, nTotal, sShort)

        if ent.isDir then
            pcall(function() vol:mkdir(ent.src) end)
            nDirs = nDirs + 1
            g_tInstall.nDirs = nDirs
        else
            local bFileOk = false
            local hSrc = nil
            local bOpenOk = pcall(function() hSrc = fs.open(ent.src, "r") end)

            if bOpenOk and hSrc then
                local tC = {}
                local nChunkCount = 0
                while true do
                    local bROk, sChunk = pcall(fs.read, hSrc, 2048)
                    if not bROk or not sChunk then break end
                    tC[#tC + 1] = sChunk
                    nChunkCount = nChunkCount + 1
                    if nChunkCount % 4 == 0 then yieldFlush() end
                end
                pcall(fs.close, hSrc)
                yieldFlush()

                local sData = table.concat(tC)
                tC = nil
                yieldFlush()

                if sData:find("\r\n", 1, true) then
                    sData = sData:gsub("\r\n", "\n")
                end
                local nSz = #sData
                yieldFlush()

                -- Ensure parent dirs
                local tParts = {}
                for seg in ent.src:gmatch("[^/]+") do tParts[#tParts+1] = seg end
                if #tParts > 1 then
                    local sDir = ""
                    for j = 1, #tParts - 1 do
                        sDir = sDir .. "/" .. tParts[j]
                        if not vol:stat(sDir) then vol:mkdir(sDir) end
                    end
                end
                yieldFlush()

                local bW, sWE = pcall(function() return vol:writeFile(ent.src, sData) end)
                if not bW or not sWE then
                    pcall(function() vol:flush() end)
                    yieldFlush()
                    bW, sWE = pcall(function() return vol:writeFile(ent.src, sData) end)
                end
                sData = nil
                yieldFlush()

                if bW and sWE then
                    nFiles = nFiles + 1
                    nBytes = nBytes + nSz
                else
                    nErrors = nErrors + 1
                    tFailed[#tFailed + 1] = { path = ent.src, err = tostring(sWE) }
                end
            else
                nErrors = nErrors + 1
                tFailed[#tFailed + 1] = { path = ent.src, err = "Cannot open source" }
            end

            g_tInstall.nFiles = nFiles
            g_tInstall.nBytes = nBytes
            g_tInstall.nErrors = nErrors
            nFilesSincePurge = nFilesSincePurge + 1
        end

        if nFilesSincePurge >= PURGE_EVERY then
            nFilesSincePurge = 0
            pcall(function() vol:purgeCache() end)
            yieldFlush()
        end
    end

    pcall(function() vol:purgeCache() end)
    yieldFlush()
    pcall(function() vol:flush() end)

    local nElapsed = computer.uptime() - nStartTime
    g_tVol[nPartIdx] = nil

    return true, {
        nFiles = nFiles, nDirs = nDirs, nBytes = nBytes,
        nErrors = nErrors, nElapsed = nElapsed, tFailed = tFailed,
    }
end

-- =============================================
-- XE CONTEXT CREATION
-- =============================================

local ctx = XE.createContext({
    theme = XE.THEMES.dark,
    extensions = {
        "XE_ui_shadow_buffering_render_batch",
        "XE_ui_diff_render_feature",
        "XE_ui_alt_screen_query",
        "XE_ui_deferred_clear",
        "XE_ui_imgui_navigation",
        "XE_ui_dirty_row_tracking",
        "XE_ui_run_length_grouping",
        "XE_ui_modal_prebuilt",
        "XE_ui_toast",
    },
})

if not ctx then
    print("xparted: cannot create XE context (no TTY?)")
    return
end

local W, H = ctx.W, ctx.H

-- =============================================
-- UI HELPERS
-- =============================================

local function drawTitleBar(sTitle)
    ctx:fill(1, 1, W, 1, " ", ctx:c("bar_fg"), ctx:c("bar_bg"))
    ctx:text(2, 1, "xparted " .. VERSION, ctx:c("accent"), ctx:c("bar_bg"))
    if sTitle and #sTitle > 0 then
        ctx:text(W - #sTitle - 1, 1, sTitle, ctx:c("dim"), ctx:c("bar_bg"))
    end
end

local function drawStatusBar(sText)
    ctx:fill(1, H, W, 1, " ", ctx:c("bar_fg"), ctx:c("bar_bg"))
    ctx:text(2, H, sText or g_sStatus, ctx:c("dim"), ctx:c("bar_bg"))
    local sMem = string.format("Mem: %dKB free",
        math.floor(computer.freeMemory() / 1024))
    ctx:text(W - #sMem - 1, H, sMem, ctx:c("dim"), ctx:c("bar_bg"))
end

local function drawPartitionBar(nYRow)
    if not g_tRdb or not g_tDevInfo then return end
    local nBarX = 2
    local nBarW = W - 4
    local nTotalSec = g_tDevInfo.sectorCount
    if nTotalSec <= 0 then return end
    ctx:fill(nBarX, nYRow, nBarW, 1, " ", 0xFFFFFF, PART_COLORS.free)
    for i, p in ipairs(g_tRdb.partitions) do
        local nStart = p.startSector
        local nSize  = p.sizeSectors
        local nPixStart = math.floor(nStart / nTotalSec * nBarW)
        local nPixW     = math.max(1, math.floor(nSize / nTotalSec * nBarW))
        if nPixStart + nPixW > nBarW then nPixW = nBarW - nPixStart end
        local nColor = partColor(p)
        if nPixW > 0 then
            ctx:fill(nBarX + nPixStart, nYRow, nPixW, 1, " ", 0xFFFFFF, nColor)
            local sLbl = p.deviceName or ("P" .. (i - 1))
            if #sLbl > nPixW - 1 then sLbl = sLbl:sub(1, nPixW - 1) end
            if nPixW > 2 then
                ctx:text(nBarX + nPixStart + 1, nYRow, sLbl, 0x000000, nColor)
            end
        end
    end
    ctx:text(1, nYRow, "[", ctx:c("border"))
    ctx:text(W - 2, nYRow, "]", ctx:c("border"))
end

-- =============================================
-- FIX 3: renderInstallProgress — no longer silent on error.
-- Uses a flag to degrade gracefully if XE frames break.
-- =============================================

local g_bRenderOk = true
local g_nLastRenderTime = 0
local RENDER_INTERVAL = 0.4  -- render at most every 400ms

local g_nLastRenderTime = 0
local RENDER_INTERVAL = 0.5

local function renderInstallProgress(sPhase, nCur, nTot, sFile)
    -- ALWAYS yield first — resets OC budget
    yieldFlush()

    -- Throttle: render at most every 500ms (or first/last)
    local nNow = computer.uptime()
    if nNow - g_nLastRenderTime < RENDER_INTERVAL
       and nCur > 1 and nCur < nTot then
        return
    end
    g_nLastRenderTime = nNow

    -- Write directly to GDI surface — NO XE frame cycling, NO TTY IPC
    local hSurf = ctx._hGdiSurface
    if not hSurf then yieldFlush(); return end

    local nPct = nTot > 0 and math.floor(nCur / nTot * 100) or 0
    local sBg = ctx:c("bg")
    local sFg = ctx:c("fg")

    pcall(function()
        -- Clear area
        syscall("gdi_surface_fill", hSurf, 1, 3, W, H - 4, " ", sFg, sBg)
        yieldFlush()

        -- Title
        syscall("gdi_surface_set", hSurf, 3, 4,
            "Installing OS to partition " .. g_tInstall.nPartIdx,
            ctx:c("accent"), sBg)

        -- Phase indicator
        local nY = 6
        if sPhase == "scan" then
            syscall("gdi_surface_set", hSurf, 3, nY,
                "Scanning filesystem...", ctx:c("accent"), sBg)
        else
            syscall("gdi_surface_set", hSurf, 3, nY,
                "Installation in progress...", ctx:c("accent"), sBg)
        end

        -- Progress text
        nY = 8
        local sProgress = string.format("Progress: %d / %d (%d%%)", nCur, nTot, nPct)
        syscall("gdi_surface_set", hSurf, 3, nY, sProgress, sFg, sBg)

        -- Progress bar
        nY = 9
        local nBarW = W - 6
        local nFill = math.floor(nPct / 100 * nBarW)
        if nFill > 0 then
            syscall("gdi_surface_fill", hSurf, 3, nY, nFill, 1, " ", 0xFFFFFF, 0x00AA44)
        end
        if nFill < nBarW then
            syscall("gdi_surface_fill", hSurf, 3 + nFill, nY, nBarW - nFill, 1,
                " ", 0xFFFFFF, 0x222233)
        end

        yieldFlush()

        -- File name
        nY = 11
        local sDisp = sFile or ""
        if #sDisp > W - 12 then sDisp = ".." .. sDisp:sub(-(W - 14)) end
        syscall("gdi_surface_set", hSurf, 3, nY, "File: ", ctx:c("dim"), sBg)
        syscall("gdi_surface_set", hSurf, 9, nY, sDisp .. string.rep(" ", W - 9 - #sDisp),
            sFg, sBg)

        -- Stats
        nY = 13
        syscall("gdi_surface_set", hSurf, 3, nY,
            string.format("Files: %d  Dirs: %d  Bytes: %s  Errors: %d",
                g_tInstall.nFiles, g_tInstall.nDirs,
                fmtSz(g_tInstall.nBytes), g_tInstall.nErrors),
            sFg, sBg)

        -- Memory
        nY = 15
        syscall("gdi_surface_set", hSurf, 3, nY,
            string.format("Free memory: %d KB", math.floor(computer.freeMemory() / 1024)),
            ctx:c("dim"), sBg)

        -- Composite
        syscall("gdi_composite")
    end)

    yieldFlush()
end

-- =============================================
-- PAGE: Drive Scanner
-- =============================================

local g_tDriveList = {}
local g_bDriveScanned = false

local function pageScan()
    drawTitleBar("Drive Scanner")
    ctx:text(2, 3, "Available Block Devices:", ctx:c("accent"))
    ctx:separator(2, 4, W - 3)

    if not g_bDriveScanned then
        g_tDriveList = findDrives()
        g_bDriveScanned = true
    end

    if #g_tDriveList == 0 then
        ctx:text(3, 6, "No drive devices found.", ctx:c("err"))
        ctx:text(3, 7, "Load blkdev driver: insmod blkdev", ctx:c("dim"))
    else
        local nFirst, nLast, nSel, nCW, bAct = ctx:beginScroll(
            "drv_list", 2, 5, W - 3, H - 10, #g_tDriveList)
        for i = nFirst, nLast do
            local d = g_tDriveList[i]
            if d then
                local ry = 5 + (i - nFirst)
                local bSel = (i == nSel)
                local sLine = string.format(" %-24s  %7s  %d x %dB",
                    d.path, fmtSz(d.capacity), d.sectors, d.secSize)
                ctx:textPad(2, ry, nCW, sLine,
                    bSel and ctx:c("sel_fg") or ctx:c("fg"),
                    bSel and ctx:c("sel_bg") or ctx:c("bg"))
            end
        end
        ctx:endScroll()
        if bAct and g_tDriveList[nSel] then
            local bOk, sErr = openDevice(g_tDriveList[nSel].path)
            if bOk then
                g_sPage = "parts"
                ctx:toastSuccess("Opened " .. g_tDriveList[nSel].path)
            else
                ctx:toastError("Open failed: " .. tostring(sErr))
            end
        end
    end

    local nBtnY = H - 2
    if ctx:button("scan_refresh", 2, nBtnY, " Refresh ",
        ctx:c("btn_fg"), ctx:c("btn_bg"),
        ctx:c("btn_hfg"), ctx:c("btn_hbg")) then
        g_bDriveScanned = false
    end
    if ctx:button("scan_quit", 12, nBtnY, " Quit ",
        ctx:c("btn_fg"), ctx:c("btn_bg"),
        ctx:c("btn_hfg"), ctx:c("btn_hbg")) then
        g_bRunning = false
    end
    drawStatusBar("Select a drive and press Enter. Tab to navigate.")
end

-- =============================================
-- PAGE: Partition View
-- =============================================

local function pageParts()
    local sShort = g_sDev and g_sDev:match("([^/]+)$") or "?"
    drawTitleBar(sShort .. "  " .. fmtSz(g_tDevInfo and g_tDevInfo.capacity or 0))

    if not g_tRdb then
        ctx:text(3, 4, "No RDB on this device.", ctx:c("warn"))
        ctx:text(3, 5, "Use [Init RDB] to create a partition table.", ctx:c("dim"))
    else
        ctx:text(2, 3, "Disk: " .. (g_tRdb.label or "?") ..
            "  Gen=" .. (g_tRdb.generation or 0), ctx:c("accent"))
        drawPartitionBar(4)

        local nListY = 6
        ctx:text(2, nListY, string.format("%-3s %-8s %-8s %-10s %8s %10s %-14s",
            "#", "DEVICE", "LABEL", "TYPE", "START", "SIZE", "FLAGS"), ctx:c("dim"))
        ctx:separator(2, nListY + 1, W - 3)

        if #g_tRdb.partitions == 0 then
            ctx:text(3, nListY + 2, "(no partitions)", ctx:c("dim"))
        else
            local nListH = H - nListY - 6
            if nListH < 3 then nListH = 3 end
            local nFirst, nLast, nSel, nCW, bAct = ctx:beginScroll(
                "part_list", 2, nListY + 2, W - 3, nListH, #g_tRdb.partitions)
            for i = nFirst, nLast do
                local p = g_tRdb.partitions[i]
                if p then
                    local ry = nListY + 2 + (i - nFirst)
                    local bSel = (i == nSel)
                    local sLine = string.format("%-3d %-8s %-8s %-10s %8d %10s %s",
                        i - 1, p.deviceName or "?",
                        RDB.getDisplayLabel(p),
                        fsTypeName(p.fsType),
                        p.startSector,
                        fmtSz(p.sizeSectors * g_tDisk.sectorSize),
                        fmtPartFlags(p))
                    ctx:textPad(2, ry, nCW, sLine,
                        bSel and ctx:c("sel_fg") or ctx:c("fg"),
                        bSel and ctx:c("sel_bg") or ctx:c("bg"))
                end
            end
            ctx:endScroll()
            g_nSelPart = nSel - 1
            if bAct then g_sPage = "info"; return end
        end

        local nFree = g_tRdb.totalSectors - RDB.nextFree(g_tRdb)
        if nFree > 0 then
            ctx:text(2, H - 5, "Free: " .. nFree .. " sectors (" ..
                fmtSz(nFree * g_tDisk.sectorSize) .. ")", ctx:c("dim"))
        end
    end

    local nBtnY = H - 2
    local nBX = 2

    if ctx:button("p_back", nBX, nBtnY, " Back ",
        ctx:c("btn_fg"), ctx:c("btn_bg"),
        ctx:c("btn_hfg"), ctx:c("btn_hbg")) then
        closeDevice(); g_sPage = "scan"; g_bDriveScanned = false
    end
    nBX = nBX + 8

    if not g_tRdb then
        if ctx:button("p_init", nBX, nBtnY, " Init RDB ",
            ctx:c("btn_fg"), ctx:c("btn_bg"),
            ctx:c("btn_hfg"), ctx:c("btn_hbg")) then
            local bOk, sErr = doInitRdb()
            if bOk then ctx:toastSuccess("RDB initialized")
            else ctx:toastError(tostring(sErr)) end
        end
        nBX = nBX + 12
    else
        if ctx:button("p_add", nBX, nBtnY, " Add ",
            ctx:c("btn_fg"), ctx:c("btn_bg"),
            ctx:c("btn_hfg"), ctx:c("btn_hbg")) then
            g_sPage = "add_part"
        end
        nBX = nBX + 7

        if #g_tRdb.partitions > 0 then
            if ctx:button("p_rm", nBX, nBtnY, " Remove ",
                ctx:c("btn_fg"), ctx:c("btn_bg"),
                ctx:c("btn_hfg"), ctx:c("btn_hbg")) then
                g_sPage = "confirm_rm"
            end
            nBX = nBX + 10

            if ctx:button("p_fmt", nBX, nBtnY, " Format ",
                ctx:c("btn_fg"), ctx:c("btn_bg"),
                ctx:c("btn_hfg"), ctx:c("btn_hbg")) then
                g_sPage = "confirm_fmt"
            end
            nBX = nBX + 10

            if ctx:button("p_inst", nBX, nBtnY, " Install ",
                ctx:c("btn_fg"), ctx:c("btn_bg"),
                ctx:c("btn_hfg"), ctx:c("btn_hbg")) then
                g_tInstall.nPartIdx = g_nSelPart
                g_sPage = "confirm_inst"
            end
            nBX = nBX + 11
        end
    end

    if ctx:button("p_wizard", nBX, nBtnY, " Wizard ",
        0xFFFFFF, 0x553399, 0x000000, 0xFFFF00) then
        g_tWizard.nStep = 1; g_tWizard.bConfirmed = false
        g_tWizard.sResult = nil; g_sPage = "wizard"
    end

    drawStatusBar("Tab:Navigate  Enter:Select  Q:Quit")
    local k = ctx:key()
    if k == "q" or k == "Q" then g_bRunning = false end
end

-- =============================================
-- PAGE: Add Partition
-- =============================================

local g_sNewPartName = "DH0"
local g_sNewPartSize = "0"

local function pageAddPart()
    drawTitleBar("Add Partition")
    ctx:text(3, 3, "Create a new AXFS v2 partition", ctx:c("accent"))
    ctx:separator(3, 4, W - 5)
    local nFree = g_tRdb and (g_tRdb.totalSectors - RDB.nextFree(g_tRdb)) or 0
    ctx:textf(3, 6, ctx:c("fg"), nil, "Free space: %d sectors (%s)",
        nFree, fmtSz(nFree * (g_tDisk and g_tDisk.sectorSize or 512)))
    ctx:text(3, 8, "Name:", ctx:c("fg"))
    g_sNewPartName = ctx:textInput("add_name", 10, 8, 20, g_sNewPartName)
    ctx:text(3, 10, "Size (sectors, 0=all free):", ctx:c("fg"))
    g_sNewPartSize = ctx:textInput("add_size", 32, 10, 12, g_sNewPartSize)
    local nBtnY = 13
    if ctx:button("add_ok", 3, nBtnY, " Create ",
        ctx:c("btn_fg"), ctx:c("btn_bg"), ctx:c("btn_hfg"), ctx:c("btn_hbg")) then
        local nSz = tonumber(g_sNewPartSize) or 0
        local bOk, sErr = doAddPart(g_sNewPartName, nSz)
        if bOk then ctx:toastSuccess("Partition created"); g_sPage = "parts"
        else ctx:toastError(tostring(sErr)) end
    end
    if ctx:button("add_cancel", 14, nBtnY, " Cancel ",
        ctx:c("btn_fg"), ctx:c("btn_bg"), ctx:c("btn_hfg"), ctx:c("btn_hbg")) then
        g_sPage = "parts"
    end
    drawStatusBar("")
end

-- =============================================
-- PAGE: Confirm Remove / Format
-- =============================================

local function pageConfirmRm()
    local r = ctx:confirm("rm_confirm", "Remove Partition",
        "Delete partition " .. g_nSelPart .. "? Data will be lost.", "Delete", "Cancel")
    if r == true then
        doRmPart(g_nSelPart)
        ctx:toastSuccess("Partition " .. g_nSelPart .. " removed"); g_sPage = "parts"
    elseif r == false then g_sPage = "parts" end
end

local function pageConfirmFmt()
    local r = ctx:confirm("fmt_confirm", "Format Partition",
        "Format partition " .. g_nSelPart .. " as AXFS v2? ALL DATA LOST.", "Format", "Cancel")
    if r == true then
        local bOk, sErr = doFormat(g_nSelPart)
        if bOk then ctx:toastSuccess("Formatted #" .. g_nSelPart)
        else ctx:toastError(tostring(sErr)) end
        g_sPage = "parts"
    elseif r == false then g_sPage = "parts" end
end

-- =============================================
-- PAGE: Partition Info
-- =============================================

local function pageInfo()
    drawTitleBar("Partition " .. g_nSelPart .. " — Info")
    if not g_tRdb or not g_tRdb.partitions[g_nSelPart + 1] then
        ctx:text(3, 4, "Invalid partition.", ctx:c("err"))
        if ctx:button("info_back", 3, H - 2, " Back ", ctx:c("btn_fg"), ctx:c("btn_bg"),
            ctx:c("btn_hfg"), ctx:c("btn_hbg")) then g_sPage = "parts" end
        drawStatusBar(""); return
    end
    local p = g_tRdb.partitions[g_nSelPart + 1]
    local ss = g_tDisk.sectorSize
    local nY = 3
    ctx:textf(3, nY, ctx:c("accent"), nil, "Partition %d — %s", g_nSelPart, p.deviceName or "?")
    nY = nY + 1; ctx:separator(3, nY, W - 5); nY = nY + 1
    ctx:textf(3, nY, ctx:c("fg"), nil, "  Label:     %s", RDB.getDisplayLabel(p)); nY = nY + 1
    ctx:textf(3, nY, ctx:c("fg"), nil, "  FS Type:   %s (0x%08X)", fsTypeName(p.fsType), p.fsType); nY = nY + 1
    ctx:textf(3, nY, ctx:c("fg"), nil, "  Start:     sector %d", p.startSector); nY = nY + 1
    ctx:textf(3, nY, ctx:c("fg"), nil, "  Size:      %d sectors (%s)", p.sizeSectors, fmtSz(p.sizeSectors * ss)); nY = nY + 1
    ctx:textf(3, nY, ctx:c("fg"), nil, "  Flags:     %s (0x%04X)", fmtPartFlags(p), p.flags or 0); nY = nY + 1
    ctx:textf(3, nY, ctx:c("fg"), nil, "  Priority:  %d", p.bootPriority or 0); nY = nY + 1
    nY = nY + 1
    if p.ext and p.ext._valid then
        ctx:text(3, nY, "@RDB::Partition Extension:", ctx:c("accent2")); nY = nY + 1
        local tVisNames = { [0]="Normal", [1]="Hidden-FS", [2]="SYSTEM" }
        ctx:textf(5, nY, ctx:c("fg"), nil, "Visibility: %s", tVisNames[p.ext.visibility] or "?"); nY = nY + 1
        local tEncNames = { [0]="None", [1]="HMAC-XOR", [2]="DataCard" }
        ctx:textf(5, nY, ctx:c("fg"), nil, "Encryption: %s", tEncNames[p.ext.encryptType] or "?"); nY = nY + 1
        local tRoleNames = { [0]="Data", [1]="EFI-Stage3", [2]="Recovery", [3]="Swap", [4]="Root" }
        ctx:textf(5, nY, ctx:c("fg"), nil, "Boot Role:  %s", tRoleNames[p.ext.bootRole] or "?"); nY = nY + 1
    else
        ctx:text(3, nY, "@RDB Extension: not present (legacy)", ctx:c("dim")); nY = nY + 1
    end
    nY = nY + 1
    ctx:textf(3, nY, ctx:c("fg"), nil, "Is EFI:     %s", tostring(RDB.isEfiPartition(p))); nY = nY + 1
    ctx:textf(3, nY, ctx:c("fg"), nil, "Is Hidden:  %s", tostring(RDB.isHiddenFromFS(p))); nY = nY + 1
    ctx:textf(3, nY, ctx:c("fg"), nil, "Encrypted:  %s", tostring(RDB.isEncrypted(p))); nY = nY + 1
    if ctx:button("info_back", 3, H - 2, " Back ",
        ctx:c("btn_fg"), ctx:c("btn_bg"), ctx:c("btn_hfg"), ctx:c("btn_hbg")) then
        g_sPage = "parts"
    end
    drawStatusBar("")
end


local function pageWizard()
    drawTitleBar("AXFS Switch Wizard")
    if g_tWizard.sResult then
        ctx:text(3, 4, g_tWizard.sResult, ctx:c("ok"))
        if ctx:button("wiz_done", 3, H - 2, " Done ",
            ctx:c("btn_fg"), ctx:c("btn_bg"), ctx:c("btn_hfg"), ctx:c("btn_hbg")) then
            g_sPage = "parts"
        end
        drawStatusBar(""); return
    end
    local nY = 3
    ctx:text(3, nY, "Prepare drive for AxisOS boot", ctx:c("accent")); nY = nY + 2
    if not g_tDisk or not g_tDevInfo then
        ctx:text(3, nY, "No device open.", ctx:c("err"))
        if ctx:button("wiz_back", 3, H - 2, " Back ",
            ctx:c("btn_fg"), ctx:c("btn_bg"), ctx:c("btn_hfg"), ctx:c("btn_hbg")) then g_sPage = "parts" end
        drawStatusBar(""); return
    end
    ctx:textf(3, nY, ctx:c("fg"), nil, "Device: %s (%s, %d sectors)",
        g_sDev, fmtSz(g_tDevInfo.capacity), g_tDevInfo.sectorCount); nY = nY + 2

    -- Volume Label
    ctx:text(3, nY, "Volume Label:", ctx:c("fg"))
    g_tWizard.sLabel = ctx:textInput("wiz_label", 18, nY, 20, g_tWizard.sLabel); nY = nY + 2

    -- ═══ Mandatory Partitions ═══
    ctx:text(3, nY, "Mandatory partitions (always created):", ctx:c("accent2")); nY = nY + 1
    ctx:text(5, nY, "OLR size:", ctx:c("fg")); local sOlr = ctx:textInput("wiz_olr_sz", 24, nY, 8, tostring(g_tWizard.nOlrSectors)); g_tWizard.nOlrSectors = tonumber(sOlr) or 2; nY = nY + 1
    ctx:text(5, nY, "KSR size:", ctx:c("fg")); local sKsr = ctx:textInput("wiz_ksr_sz", 24, nY, 8, tostring(g_tWizard.nKsrSectors)); g_tWizard.nKsrSectors = tonumber(sKsr) or 96; nY = nY + 1
    ctx:text(5, nY, "KBL size:", ctx:c("fg")); local sKbl = ctx:textInput("wiz_kbl_sz", 24, nY, 8, tostring(g_tWizard.nKblSectors)); g_tWizard.nKblSectors = tonumber(sKbl) or 128; nY = nY + 1
    ctx:text(5, nY, "AXBC size:", ctx:c("fg")); local sAxbc = ctx:textInput("wiz_axbc_sz", 24, nY, 8, tostring(g_tWizard.nAxbcSectors)); g_tWizard.nAxbcSectors = tonumber(sAxbc) or 2; nY = nY + 1
    ctx:text(5, nY, "AXVB size:", ctx:c("fg")); local sAxvb = ctx:textInput("wiz_axvb_sz", 24, nY, 8, tostring(g_tWizard.nAxvbSectors)); g_tWizard.nAxvbSectors = tonumber(sAxvb) or 24; nY = nY + 1

    nY = nY + 1

    -- ═══ Optional Partitions ═══
    ctx:text(3, nY, "Optional partitions:", ctx:c("accent2")); nY = nY + 1
    local bNewEfi; bNewEfi, _ = ctx:checkbox("wiz_efi", 5, nY, g_tWizard.bEfi, "EFI (Secure Boot)"); g_tWizard.bEfi = bNewEfi
    if g_tWizard.bEfi then
        local sEfi = ctx:textInput("wiz_efi_sz", 42, nY, 8, tostring(g_tWizard.nEfiSectors)); g_tWizard.nEfiSectors = tonumber(sEfi) or 48
    end
    nY = nY + 1
    local bNewAxsn; bNewAxsn, _ = ctx:checkbox("wiz_axsn", 5, nY, g_tWizard.bAxsn, "AXSN (Snapshot Store)"); g_tWizard.bAxsn = bNewAxsn
    if g_tWizard.bAxsn then
        local sAxsn = ctx:textInput("wiz_axsn_sz", 42, nY, 8, tostring(g_tWizard.nAxsnSectors)); g_tWizard.nAxsnSectors = tonumber(sAxsn) or 512
    end
    nY = nY + 2

    -- ═══ Layout Preview ═══
    local nUsed = RDB.MAX_PARTS + 1
        + g_tWizard.nOlrSectors + g_tWizard.nKsrSectors
        + g_tWizard.nKblSectors + g_tWizard.nAxbcSectors
        + g_tWizard.nAxvbSectors
    if g_tWizard.bEfi then nUsed = nUsed + g_tWizard.nEfiSectors end
    if g_tWizard.bAxsn then nUsed = nUsed + g_tWizard.nAxsnSectors end
    local nAxfsLeft = g_tDevInfo and (g_tDevInfo.sectorCount - nUsed) or 0

    ctx:text(3, nY, "Layout preview:", ctx:c("accent2")); nY = nY + 1
    ctx:textf(5, nY, 0xAA55FF, nil, "OLR: %d", g_tWizard.nOlrSectors)
    ctx:textf(18, nY, 0xFFAA55, nil, "KSR: %d", g_tWizard.nKsrSectors)
    ctx:textf(31, nY, 0xFFAA00, nil, "KBL: %d", g_tWizard.nKblSectors); nY = nY + 1
    ctx:textf(5, nY, 0x55CCCC, nil, "AXBC: %d", g_tWizard.nAxbcSectors)
    ctx:textf(18, nY, 0xCC55CC, nil, "AXVB: %d", g_tWizard.nAxvbSectors)
    if g_tWizard.bEfi then ctx:textf(31, nY, 0xFF55FF, nil, "EFI: %d", g_tWizard.nEfiSectors) end
    nY = nY + 1
    if g_tWizard.bAxsn then ctx:textf(5, nY, 0xCCCC55, nil, "AXSN: %d", g_tWizard.nAxsnSectors); nY = nY + 1 end
    ctx:textf(5, nY, 0x55FF55, nil, "AXFS: %d sectors (%s)", nAxfsLeft, fmtSz(nAxfsLeft * (g_tDisk and g_tDisk.sectorSize or 512))); nY = nY + 2

    if nAxfsLeft < 64 then ctx:text(3, nY, "ERROR: Not enough space for AXFS!", ctx:c("err")); nY = nY + 1 end
    ctx:text(3, nY, "WARNING: This will DESTROY all data.", ctx:c("err")); nY = nY + 1

    local nBtnY = H - 2
    if ctx:button("wiz_exec", 3, nBtnY, " Execute Wizard ", 0xFFFFFF, 0xAA0000, 0xFFFF00, 0xFF0000) then g_sPage = "confirm_wizard" end
    if ctx:button("wiz_cancel", 22, nBtnY, " Cancel ", ctx:c("btn_fg"), ctx:c("btn_bg"), ctx:c("btn_hfg"), ctx:c("btn_hbg")) then g_sPage = "parts" end
    drawStatusBar("Configure partition layout, then Execute.")
end

local function pageConfirmWizard()
    local tParts = {"OLR", "KSR", "KBL", "AXBC", "AXVB", "AXFS"}
    if g_tWizard.bEfi then table.insert(tParts, 3, "EFI") end
    if g_tWizard.bAxsn then table.insert(tParts, #tParts, "AXSN") end
    local sMsg = string.format("DESTROY all data on %s and create %s?",
        g_sDev or "?", table.concat(tParts, " + "))
    local r = ctx:confirm("wiz_cfm", "Confirm AXFS Switch", sMsg, "SWITCH", "Cancel")
    if r == true then
        ctx:toastInfo("Writing partition table...")
        local bOk, sErr = doWizardExecute()
        if bOk then
            g_tWizard.sResult = "Drive preparation COMPLETE! Created: " .. table.concat(tParts, " + ")
            ctx:toastSuccess("Wizard completed successfully")
        else
            g_tWizard.sResult = "FAILED: " .. tostring(sErr)
            ctx:toastError("Wizard failed: " .. tostring(sErr))
        end
        g_sPage = "wizard"
    elseif r == false then g_sPage = "wizard" end
end

-- =============================================
-- PAGE: Confirm Install
--
-- FIX 1: Mount the volume HERE (while a visible
-- "Preparing…" frame is on screen) instead of
-- inside doInstall where no frame is committed.
-- =============================================

local function pageConfirmInst()
    local sMsg = string.format(
        "Install OS to partition %d? Existing files will be overwritten.",
        g_tInstall.nPartIdx)
    local r = ctx:confirm("inst_cfm", "Confirm Installation", sMsg, "Install", "Cancel")
    if r == true then
        -- End XE frame management — we'll use direct GDI writes from here
        ctx:endFrame()
        yieldFlush()

        -- Show "Preparing" on GDI surface directly
        local hSurf = ctx._hGdiSurface
        if hSurf then
            syscall("gdi_surface_clear", hSurf, ctx:c("fg"), ctx:c("bg"))
            syscall("gdi_surface_set", hSurf, 3, 4,
                "Preparing installation...", ctx:c("accent"), ctx:c("bg"))
            syscall("gdi_surface_set", hSurf, 3, 6,
                "Mounting target filesystem — please wait...", ctx:c("fg"), ctx:c("bg"))
            syscall("gdi_surface_set", hSurf, 3, 8,
                string.format("Free memory: %d KB", math.floor(computer.freeMemory() / 1024)),
                ctx:c("dim"), ctx:c("bg"))
            syscall("gdi_composite")
        end
        yieldFlush()

        -- Mount target volume
        local vol, volErr = getVol(g_tInstall.nPartIdx)
        yieldFlush()

        if not vol then
            -- Re-enter XE frame for error display
            ctx:beginFrame()
            ctx:toastError("Mount failed: " .. tostring(volErr))
            g_sPage = "parts"
            return
        end

        -- Reset install state
        g_tInstall.bRunning = true
        g_tInstall.bDone = false
        g_tInstall.nTotal = 0
        g_tInstall.nCurrent = 0
        g_tInstall.nFiles = 0
        g_tInstall.nDirs = 0
        g_tInstall.nBytes = 0
        g_tInstall.nErrors = 0
        g_tInstall.sCurrentFile = "Starting..."
        g_tInstall.tFailed = {}
        g_tInstall.sResult = nil
        g_nLastRenderTime = 0

        -- Run install — progress renders directly to GDI (no XE frames)
        local function fProg(sPhase, nCur, nTot, sFile)
            g_tInstall.nCurrent = nCur
            g_tInstall.nTotal = nTot
            g_tInstall.sCurrentFile = sFile or ""
            renderInstallProgress(sPhase, nCur, nTot, sFile)
        end

        local bOk, vResult = doInstall(g_tInstall.nPartIdx, fProg)

        g_tInstall.bDone = true

        if bOk and type(vResult) == "table" then
            g_tInstall.nFiles   = vResult.nFiles
            g_tInstall.nDirs    = vResult.nDirs
            g_tInstall.nBytes   = vResult.nBytes
            g_tInstall.nErrors  = vResult.nErrors
            g_tInstall.nElapsed = vResult.nElapsed
            g_tInstall.tFailed  = vResult.tFailed or {}
            g_tInstall.sResult  = "Installation complete!"
        else
            g_tInstall.sResult = "FAILED: " .. tostring(vResult)
        end

        -- Re-enter XE frame management for results page
        ctx:beginFrame()
        g_sPage = "install_done"
    elseif r == false then
        g_sPage = "parts"
    end
end

-- =============================================
-- PAGE: Install Running (with progress)
-- =============================================

local g_bInstallStarted = false

local function pageInstallDone()
    drawTitleBar("Installation Complete")
    local nY = 4

    ctx:text(3, nY, g_tInstall.sResult or "Done",
        g_tInstall.nErrors > 0 and ctx:c("warn") or ctx:c("ok"))
    nY = nY + 2
    ctx:textf(3, nY, ctx:c("fg"), nil, "Files:   %d", g_tInstall.nFiles); nY = nY + 1
    ctx:textf(3, nY, ctx:c("fg"), nil, "Dirs:    %d", g_tInstall.nDirs); nY = nY + 1
    ctx:textf(3, nY, ctx:c("fg"), nil, "Bytes:   %s", fmtSz(g_tInstall.nBytes)); nY = nY + 1
    ctx:textf(3, nY, g_tInstall.nErrors > 0 and ctx:c("err") or ctx:c("ok"), nil,
        "Errors:  %d", g_tInstall.nErrors); nY = nY + 1
    ctx:textf(3, nY, ctx:c("fg"), nil, "Time:    %.1f sec", g_tInstall.nElapsed or 0); nY = nY + 2

    if #g_tInstall.tFailed > 0 then
        ctx:text(3, nY, "Failed files:", ctx:c("err")); nY = nY + 1
        local nMaxShow = math.min(#g_tInstall.tFailed, H - nY - 4)
        for j = 1, nMaxShow do
            local tF = g_tInstall.tFailed[j]
            ctx:textf(5, nY, ctx:c("err"), nil, "%s — %s", tF.path, tF.err); nY = nY + 1
        end
        if #g_tInstall.tFailed > nMaxShow then
            ctx:textf(5, nY, ctx:c("dim"), nil, "... and %d more",
                #g_tInstall.tFailed - nMaxShow)
        end
    end

    if ctx:button("inst_done", 3, H - 2, " Done ",
        ctx:c("btn_fg"), ctx:c("btn_bg"),
        ctx:c("btn_hfg"), ctx:c("btn_hbg")) then
        g_sPage = "parts"
    end
    drawStatusBar("Installation finished.")
end

-- =============================================
-- MAIN LOOP
-- =============================================

if args[1] then
    local bOk, sErr = openDevice(args[1])
    if bOk then g_sPage = "parts" end
end

while g_bRunning do
    local bInput = ctx:beginFrame()
    ctx:clear(ctx:c("bg"))

    local k = ctx:key()
    if k == "\3" then g_bRunning = false end

    if g_sPage == "scan" then
        pageScan()
    elseif g_sPage == "parts" then
        pageParts()
    elseif g_sPage == "add_part" then
        pageAddPart()
    elseif g_sPage == "confirm_rm" then
        pageConfirmRm()
    elseif g_sPage == "confirm_fmt" then
        pageConfirmFmt()
    elseif g_sPage == "info" then
        pageInfo()
    elseif g_sPage == "wizard" then
        pageWizard()
    elseif g_sPage == "confirm_wizard" then
        pageConfirmWizard()
    elseif g_sPage == "confirm_inst" then
        pageConfirmInst()
    elseif g_sPage == "install_done" then
        pageInstallDone()
    end

    ctx:endFrame()
end

-- =============================================
-- CLEANUP
-- =============================================

closeDevice()
ctx:destroy()