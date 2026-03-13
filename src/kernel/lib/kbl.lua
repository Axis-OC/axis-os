--
-- /lib/kbl.lua
-- Kernel Bootloader Partition Manager v2
--
-- KBL v2 Partition Layout (128 sectors, 64KB):
--   Sector 0:       Header (256B metadata + 256B EEPROM offload)
--   Sectors 1-3:    loader.cfg (1536B max)
--   Sectors 4-50:   Stage2 boot code (~24KB max)
--   Sectors 51-100: KBL shell code (~25KB max)
--   Sectors 101-124: Variable store
--   Sectors 125-127: Reserved
--
-- Header v2 byte map (first 256 bytes):
--   [1-4]     "AXKB"
--   [5]       Version (2)
--   [6]       Config flags
--   [7-8]     Stage2 code size (uint16)
--   [9-12]    Stage2 CRC32
--   [13-14]   Stage2 start sector (relative)
--   [15-16]   Stage2 sector count
--   [17-18]   Shell start sector (relative)
--   [19-20]   Shell sector count
--   [21-22]   Shell code size (uint16)
--   [23-26]   Shell CRC32
--   [27-28]   Loader.cfg start sector (relative)
--   [29-30]   Loader.cfg sector count
--   [31-32]   Loader.cfg size (uint16)
--   [33-64]   Label (32 bytes)
--   [65-68]   Boot attempt counter
--   [69-72]   Last enter timestamp
--   [73-76]   Kernel fail count
--   [77-78]   Var start sector
--   [79-80]   Var sector count
--   [81-84]   Loader.cfg CRC32
--   [85-96]   Reserved
--   [97-240]  Inline variables (144 bytes)
--   [241-244] Inline var CRC
--   [245-248] Header CRC
--   [249-256] Padding
--
-- EEPROM offload (bytes 257-512):
--   [257-260] "AXEO"
--   [261]     SB mode
--   [262]     Default boot entry
--   [263]     Timeout (seconds)
--   [264]     Quick boot
--   [265]     Log level
--   [266-268] Reserved
--   [269-332] Machine binding (64B, encrypted)
--   [333-396] Kernel hash (64B, encrypted)
--   [397-460] Manifest hash (64B, encrypted)
--   [461-492] PK fingerprint (32B, encrypted)
--   [493-496] Boot counter (uint32)
--   [497-500] Last good boot (uint32)
--   [501-504] Offload CRC
--   [505-512] Padding
--

local B = require("bpack")
local KBL = {}

KBL.MAGIC        = "AXKB"
KBL.VERSION      = 2
KBL.FS_TYPE      = 0x41584B42
KBL.DEFAULT_SIZE = 128  -- sectors

-- Default layout sector offsets (relative to partition start)
KBL.LAYOUT = {
    LOADER_START  = 1,
    LOADER_COUNT  = 3,
    STAGE2_START  = 4,
    STAGE2_COUNT  = 47,
    SHELL_START   = 51,
    SHELL_COUNT   = 70,    -- was 50 (now 35,840 bytes max)
    VAR_START     = 121,   -- was 101
    VAR_COUNT     = 4,     -- was 24 (inline vars only use 144B anyway)
}

-- Configuration flags
KBL.CFG_FORCE_ENTER = 0x01
KBL.CFG_FALLBACK    = 0x02
KBL.CFG_LOCKED      = 0x04
KBL.CFG_VERBOSE     = 0x08
KBL.CFG_AUTO_CLEAR  = 0x10

KBL.EEPROM_OFFLOAD_MAGIC = "AXEO"

-- =============================================
-- HEADER PACK/UNPACK
-- =============================================

function KBL.PackHeader(t, nSS)
    local s = KBL.MAGIC
        .. B.u8(KBL.VERSION)
        .. B.u8(t.nConfig or KBL.CFG_FALLBACK + KBL.CFG_AUTO_CLEAR)
        -- Stage2
        .. B.u16(t.nStage2Size or 0)
        .. B.u32(t.nStage2Crc or 0)
        .. B.u16(t.nStage2Start or KBL.LAYOUT.STAGE2_START)
        .. B.u16(t.nStage2Count or 0)
        -- Shell
        .. B.u16(t.nShellStart or KBL.LAYOUT.SHELL_START)
        .. B.u16(t.nShellCount or 0)
        .. B.u16(t.nShellSize or 0)
        .. B.u32(t.nShellCrc or 0)
        -- Loader.cfg
        .. B.u16(t.nLoaderStart or KBL.LAYOUT.LOADER_START)
        .. B.u16(t.nLoaderCount or KBL.LAYOUT.LOADER_COUNT)
        .. B.u16(t.nLoaderSize or 0)
        -- Label
        .. B.pad(t.sLabel or "KBL", 32)
        -- Counters
        .. B.u32(t.nBootAttempts or 0)
        .. B.u32(t.nLastEnter or 0)
        .. B.u32(t.nKernelFails or 0)
        -- Var layout
        .. B.u16(t.nVarStart or KBL.LAYOUT.VAR_START)
        .. B.u16(t.nVarCount or KBL.LAYOUT.VAR_COUNT)
        -- Loader.cfg CRC
        .. B.u32(t.nLoaderCrc or 0)
        -- Reserved
        .. B.pad("", 12)
        -- Inline vars
        .. B.pad(t.sInlineVars or "", 144)
    -- Inline var CRC
    s = s .. B.u32(B.crc32(B.pad(t.sInlineVars or "", 144)))
    -- Header CRC
    s = s .. B.u32(B.crc32(s))
    return B.pad(s, 256)
end

function KBL.UnpackHeader(s)
    if not s or #s < 248 then return nil, "too short" end
    if s:sub(1, 4) ~= KBL.MAGIC then return nil, "bad magic" end
    local nVer = s:byte(5)
    local t = {
        nVersion      = nVer,
        nConfig       = s:byte(6),
    }
    if nVer >= 2 then
        -- V2 layout
        t.nStage2Size  = B.r16(s, 7)
        t.nStage2Crc   = B.r32(s, 9)
        t.nStage2Start = B.r16(s, 13)
        t.nStage2Count = B.r16(s, 15)
        t.nShellStart  = B.r16(s, 17)
        t.nShellCount  = B.r16(s, 19)
        t.nShellSize   = B.r16(s, 21)
        t.nShellCrc    = B.r32(s, 23)
        t.nLoaderStart = B.r16(s, 27)
        t.nLoaderCount = B.r16(s, 29)
        t.nLoaderSize  = B.r16(s, 31)
        t.sLabel       = B.rstr(s, 33, 32)
        t.nBootAttempts = B.r32(s, 65)
        t.nLastEnter   = B.r32(s, 69)
        t.nKernelFails = B.r32(s, 73)
        t.nVarStart    = B.r16(s, 77)
        t.nVarCount    = B.r16(s, 79)
        t.nLoaderCrc   = B.r32(s, 81)
    else
        -- V1 compatibility: fields 7-20 are shell code (old "code" fields)
        t.nStage2Size  = 0
        t.nStage2Crc   = 0
        t.nStage2Start = 0
        t.nStage2Count = 0
        t.nShellSize   = B.r16(s, 7)
        t.nShellCrc    = B.r32(s, 9)
        t.nShellStart  = B.r16(s, 13)
        t.nShellCount  = B.r16(s, 15)
        t.nVarStart    = B.r16(s, 17)
        t.nVarCount    = B.r16(s, 19)
        t.sLabel       = B.rstr(s, 21, 32)
        t.nBootAttempts = B.r32(s, 53)
        t.nLastEnter   = B.r32(s, 57)
        t.nKernelFails = B.r32(s, 61)
        t.nLoaderStart = 0
        t.nLoaderCount = 0
        t.nLoaderSize  = 0
        t.nLoaderCrc   = 0
    end
    t.sInlineVars   = s:sub(97, 240)
    t.bCrcOk = (B.r32(s, 245) == B.crc32(s:sub(1, 244)))
    return t
end

-- =============================================
-- EEPROM OFFLOAD PACK/UNPACK
-- Stored in header sector bytes 257-512
-- =============================================

function KBL.PackEepromOffload(t)
    -- Derive encryption key from hardware
    local sKey = ""
    pcall(function()
        local sSeed = "AXEO_KEY:" .. (computer.address and computer.address() or "")
        for i = 1, 32 do
            local n = 0
            for j = 1, #sSeed do n = (n * 31 + sSeed:byte(j) + i) % 256 end
            sKey = sKey .. string.char(n)
        end
    end)
    if #sKey == 0 then sKey = string.rep("\x42", 32) end

    local function enc(s, nLen)
        s = B.pad(s or "", nLen)
        local t = {}
        for i = 1, nLen do
            t[i] = string.char(bit32.bxor(s:byte(i), sKey:byte(((i - 1) % #sKey) + 1)))
        end
        return table.concat(t)
    end

    local s = KBL.EEPROM_OFFLOAD_MAGIC
        .. B.u8(t.nSbMode or 0)
        .. B.u8(t.nDefaultEntry or 0)
        .. B.u8(t.nTimeout or 3)
        .. B.u8(t.nQuickBoot or 0)
        .. B.u8(t.nLogLevel or 2)
        .. B.pad("", 3)
        .. enc(t.sMachineBinding, 64)
        .. enc(t.sKernelHash, 64)
        .. enc(t.sManifestHash, 64)
        .. enc(t.sPkFingerprint, 32)
        .. B.u32(t.nBootCounter or 0)
        .. B.u32(t.nLastGoodBoot or 0)
    s = s .. B.u32(B.crc32(s))
    return B.pad(s, 256)
end

function KBL.UnpackEepromOffload(s)
    if not s or #s < 248 then return nil end
    if s:sub(1, 4) ~= KBL.EEPROM_OFFLOAD_MAGIC then return nil end
    return {
        nSbMode       = s:byte(5),
        nDefaultEntry = s:byte(6),
        nTimeout      = s:byte(7),
        nQuickBoot    = s:byte(8),
        nLogLevel     = s:byte(9),
        -- Encrypted fields — caller must decrypt
        sMachBinding  = s:sub(13, 76),
        sKernelHash   = s:sub(77, 140),
        sManifestHash = s:sub(141, 204),
        sPkFP         = s:sub(205, 236),
        nBootCounter  = B.r32(s, 237),
        nLastGoodBoot = B.r32(s, 241),
        bCrcOk        = (B.r32(s, 245) == B.crc32(s:sub(1, 244))),
    }
end

-- =============================================
-- VARIABLE HELPERS (unchanged from v1)
-- =============================================

function KBL.PackVars(tVars)
    local tP = {}
    for k, v in pairs(tVars) do tP[#tP + 1] = tostring(k) .. "=" .. tostring(v) end
    return table.concat(tP, "\n")
end

function KBL.UnpackVars(sData)
    local tVars = {}
    if not sData then return tVars end
    for sLine in (sData .. "\n"):gmatch("([^\n]*)\n") do
        local k, v = sLine:match("^([^=]+)=(.*)")
        if k and #k > 0 and k:byte(1) ~= 0 then tVars[k] = v end
    end
    return tVars
end

-- =============================================
-- FULL KBL PARTITION INIT (v2)
-- Writes: header + stage2 + shell + loader.cfg
-- =============================================

function KBL.Init(tDisk, nOff, nSize, tContent, tOpts)
    tOpts = tOpts or {}
    tContent = tContent or {}
    local ss = tDisk.sectorSize or 512

    -- Zero-fill entire partition
    for i = 0, nSize - 1 do
        tDisk.writeSector(nOff + i, B.pad("", ss))
    end

    local L = KBL.LAYOUT

    -- Write loader.cfg
    local sLoader = tContent.sLoaderCfg or ""
    local nLoaderSize = #sLoader
    local nLoaderSectors = math.ceil(nLoaderSize / ss)
    if nLoaderSectors > L.LOADER_COUNT then nLoaderSectors = L.LOADER_COUNT end
    for i = 0, nLoaderSectors - 1 do
        local sChunk = sLoader:sub(i * ss + 1, (i + 1) * ss)
        tDisk.writeSector(nOff + L.LOADER_START + i, B.pad(sChunk, ss))
    end

    -- Write stage2 code
    local sStage2 = tContent.sStage2Code or ""
    local nStage2Size = #sStage2
    local nStage2Sectors = math.ceil(nStage2Size / ss)
    if nStage2Sectors > L.STAGE2_COUNT then
        return false, "Stage2 too large (" .. nStage2Size .. " bytes)"
    end
    for i = 0, nStage2Sectors - 1 do
        local sChunk = sStage2:sub(i * ss + 1, (i + 1) * ss)
        tDisk.writeSector(nOff + L.STAGE2_START + i, B.pad(sChunk, ss))
    end

    -- Write shell code
    local sShell = tContent.sShellCode or ""
    local nShellSize = #sShell
    local nShellSectors = math.ceil(nShellSize / ss)
    if nShellSectors > L.SHELL_COUNT then
        return false, "Shell too large (" .. nShellSize .. " bytes)"
    end
    for i = 0, nShellSectors - 1 do
        local sChunk = sShell:sub(i * ss + 1, (i + 1) * ss)
        tDisk.writeSector(nOff + L.SHELL_START + i, B.pad(sChunk, ss))
    end

    -- Build header
    local tHdr = {
        nConfig       = tOpts.nConfig or (KBL.CFG_FALLBACK + KBL.CFG_AUTO_CLEAR),
        nStage2Size   = nStage2Size,
        nStage2Crc    = nStage2Size > 0 and B.crc32(sStage2) or 0,
        nStage2Start  = L.STAGE2_START,
        nStage2Count  = nStage2Sectors,
        nShellStart   = L.SHELL_START,
        nShellCount   = nShellSectors,
        nShellSize    = nShellSize,
        nShellCrc     = nShellSize > 0 and B.crc32(sShell) or 0,
        nLoaderStart  = L.LOADER_START,
        nLoaderCount  = L.LOADER_COUNT,
        nLoaderSize   = nLoaderSize,
        nLoaderCrc    = nLoaderSize > 0 and B.crc32(sLoader) or 0,
        sLabel        = tOpts.sLabel or "KBL",
        nBootAttempts = 0,
        nLastEnter    = 0,
        nKernelFails  = 0,
        nVarStart     = L.VAR_START,
        nVarCount     = L.VAR_COUNT,
        sInlineVars   = KBL.PackVars(tOpts.tVars or {}),
    }

    -- Build EEPROM offload
    local sOffload = KBL.PackEepromOffload(tOpts.tEepromData or {
        nSbMode = 0, nDefaultEntry = 0, nTimeout = 3,
    })

    -- Write header sector (first 256B = header, second 256B = offload)
    local sHdrData = KBL.PackHeader(tHdr, 256) .. sOffload
    tDisk.writeSector(nOff, B.pad(sHdrData, ss))

    return true
end

-- =============================================
-- READ OPERATIONS
-- =============================================

function KBL.ReadHeader(tDisk, nOff)
    local s = tDisk.readSector(nOff)
    if not s or #s < 256 then return nil end
    return KBL.UnpackHeader(s)
end

function KBL.ReadEepromData(tDisk, nOff)
    local s = tDisk.readSector(nOff)
    if not s or #s < 512 then return nil end
    return KBL.UnpackEepromOffload(s:sub(257, 512))
end

function KBL.ReadLoaderCfg(tDisk, nOff, tHdr)
    if not tHdr or tHdr.nLoaderSize == 0 then return nil end
    local tC = {}
    for i = 0, tHdr.nLoaderCount - 1 do
        tC[#tC + 1] = tDisk.readSector(nOff + tHdr.nLoaderStart + i) or ""
    end
    local sCode = table.concat(tC):sub(1, tHdr.nLoaderSize)
    -- CRC verify
    if tHdr.nLoaderCrc ~= 0 and B.crc32(sCode) ~= tHdr.nLoaderCrc then
        return nil, "loader.cfg CRC mismatch"
    end
    return sCode
end

function KBL.ReadStage2(tDisk, nOff, tHdr)
    if not tHdr or tHdr.nStage2Size == 0 then return nil end
    local tC = {}
    for i = 0, tHdr.nStage2Count - 1 do
        tC[#tC + 1] = tDisk.readSector(nOff + tHdr.nStage2Start + i) or ""
    end
    local sCode = table.concat(tC):sub(1, tHdr.nStage2Size)
    if tHdr.nStage2Crc ~= 0 and B.crc32(sCode) ~= tHdr.nStage2Crc then
        return nil, "stage2 CRC mismatch"
    end
    return sCode
end

function KBL.ReadShellCode(tDisk, nOff, tHdr)
    if not tHdr or tHdr.nShellSize == 0 then return nil end
    local tC = {}
    for i = 0, tHdr.nShellCount - 1 do
        tC[#tC + 1] = tDisk.readSector(nOff + tHdr.nShellStart + i) or ""
    end
    local sCode = table.concat(tC):sub(1, tHdr.nShellSize)
    if tHdr.nShellCrc ~= 0 and B.crc32(sCode) ~= tHdr.nShellCrc then
        return nil, "shell CRC mismatch"
    end
    return sCode
end

-- =============================================
-- WRITE OPERATIONS
-- =============================================

function KBL.WriteLoaderCfg(tDisk, nOff, sLoaderCode)
    local tHdr = KBL.ReadHeader(tDisk, nOff)
    if not tHdr then return false, "no header" end
    local ss = tDisk.sectorSize or 512

    -- Write loader.cfg sectors
    local nLC = tHdr.nLoaderCount
    if nLC == 0 then nLC = KBL.LAYOUT.LOADER_COUNT end
    local nMaxSize = nLC * ss
    if #sLoaderCode > nMaxSize then
        return false, "loader.cfg too large (" .. #sLoaderCode .. " > " .. nMaxSize .. ")"
    end

    for i = 0, nLC - 1 do
        local sChunk = sLoaderCode:sub(i * ss + 1, (i + 1) * ss)
        tDisk.writeSector(nOff + tHdr.nLoaderStart + i, B.pad(sChunk, ss))
    end

    -- Update header with new size/CRC
    tHdr.nLoaderSize = #sLoaderCode
    tHdr.nLoaderCrc  = B.crc32(sLoaderCode)
    return KBL.WriteHeader(tDisk, nOff, tHdr)
end

function KBL.WriteHeader(tDisk, nOff, tHdr)
    local ss = tDisk.sectorSize or 512
    local sOld = tDisk.readSector(nOff) or B.pad("", ss)
    -- Preserve EEPROM offload (bytes 257-512)
    local sOffload = sOld:sub(257, 512)
    if #sOffload < 256 then sOffload = B.pad(sOffload, 256) end
    local sNew = KBL.PackHeader(tHdr, 256) .. sOffload
    tDisk.writeSector(nOff, B.pad(sNew, ss))
    return true
end

function KBL.WriteEepromData(tDisk, nOff, tData)
    local ss = tDisk.sectorSize or 512
    local sOld = tDisk.readSector(nOff) or B.pad("", ss)
    -- Preserve header (bytes 1-256)
    local sHdr = sOld:sub(1, 256)
    if #sHdr < 256 then sHdr = B.pad(sHdr, 256) end
    local sOffload = KBL.PackEepromOffload(tData)
    tDisk.writeSector(nOff, B.pad(sHdr .. sOffload, ss))
    return true
end

-- =============================================
-- FLAG HELPERS
-- =============================================

function KBL.SetFlag(tDisk, nOff, nFlag)
    local tHdr = KBL.ReadHeader(tDisk, nOff)
    if not tHdr then return false end
    tHdr.nConfig = bit32.bor(tHdr.nConfig, nFlag)
    return KBL.WriteHeader(tDisk, nOff, tHdr)
end

function KBL.ClearFlag(tDisk, nOff, nFlag)
    local tHdr = KBL.ReadHeader(tDisk, nOff)
    if not tHdr then return false end
    tHdr.nConfig = bit32.band(tHdr.nConfig, bit32.bnot(nFlag))
    return KBL.WriteHeader(tDisk, nOff, tHdr)
end

function KBL.HasFlag(tHdr, nFlag)
    return bit32.band(tHdr.nConfig or 0, nFlag) ~= 0
end

return KBL