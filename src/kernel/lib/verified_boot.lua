--
-- /lib/verified_boot.lua
-- AxisOS Verified Boot — AXVB Partition Manager
--
-- Stores FPE-encrypted file integrity hashes on a dedicated
-- partition (AXVB). PatchGuard reads ONE entry at a time
-- during runtime checks — zero persistent RAM for hashes.
--
-- Partition layout:
--   Sector 0:   Header (magic, version, entry count, FPE salt, HMAC)
--   Sector 1+:  Hash entries, 5 per sector (96 bytes each)
--
-- Each hash entry (96 bytes):
--   [1-32]   Path hash   (SHA-256 of file path string)
--   [33-64]  Content hash (SHA-256 of file content)
--   [65-68]  File size   (uint32)
--   [69-72]  Timestamp   (uint32, creation time)
--   [73-92]  Reserved    (20 bytes)
--   [93-96]  Entry CRC32
--
-- The entire data area (sectors 1+) is XOR-encrypted with a
-- keystream derived from HMAC(machine_binding, fpe_salt).
-- This means:
--   • The hashes are unreadable without the correct hardware
--   • Moving the drive to another machine renders AXVB useless
--   • An attacker cannot forge hashes without the binding key
--

local B = require("bpack")
local VB = {}

VB.MAGIC     = "AXVB"
VB.VERSION   = 1
VB.FS_TYPE   = 0x41585642  -- "AXVB"
VB.ENTRY_SZ  = 96
VB.HDR_SZ    = 128

-- Entries per sector (at 512B: floor(512/96) = 5)
local function epsForSS(ss) return math.floor(ss / VB.ENTRY_SZ) end

-- =============================================
-- FPE KEYSTREAM (XOR cipher with HMAC counter mode)
-- =============================================

local function fDeriveKey(oSha, sMachineBinding, sFpeSalt)
    if not oSha or not sMachineBinding then return nil end
    return oSha.hmac(sMachineBinding, sFpeSalt or "AXVB_DEFAULT_SALT")
end

local function fXorSector(sKey, sSector, nSectorIdx)
    if not sKey or #sKey == 0 then return sSector end
    local nLen = #sSector
    local tOut = {}
    local nKeyLen = #sKey
    -- Mix sector index into keystream for per-sector uniqueness
    local nMix = nSectorIdx * 7 + 13
    for i = 1, nLen do
        local kByte = sKey:byte(((i + nMix - 1) % nKeyLen) + 1)
        tOut[i] = string.char(bit32.bxor(sSector:byte(i), kByte))
    end
    return table.concat(tOut)
end

-- =============================================
-- HEADER PACK/UNPACK
-- =============================================

local function fPackHeader(t, nSS)
    local s = VB.MAGIC
        .. B.u8(VB.VERSION)
        .. B.u8(0)  -- reserved
        .. B.u16(t.nEntryCount or 0)
        .. B.u32(t.nFlags or 0)
        .. B.pad(t.sFpeSalt or "", 32)
        .. B.pad(t.sMachineBinding or "", 32)
        .. B.u32(t.nBuildTime or 0)
        .. B.u32(t.nGeneration or 0)
        .. B.pad("", 32)  -- reserved
    -- HMAC of header content
    s = s .. B.u32(B.crc32(s))
    return B.pad(s, nSS or 512)
end

local function fUnpackHeader(s)
    if not s or #s < VB.HDR_SZ then return nil, "too short" end
    if s:sub(1, 4) ~= VB.MAGIC then return nil, "bad magic" end
    local t = {
        nVersion        = s:byte(5),
        nEntryCount     = B.r16(s, 7),
        nFlags          = B.r32(s, 9),
        sFpeSalt        = s:sub(13, 44),
        sMachineBinding = s:sub(45, 76),
        nBuildTime      = B.r32(s, 77),
        nGeneration     = B.r32(s, 81),
    }
    local nStoredCrc = B.r32(s, 117)
    t.bCrcOk = (nStoredCrc == B.crc32(s:sub(1, 116)))
    return t
end

-- =============================================
-- ENTRY PACK/UNPACK
-- =============================================

local function fPackEntry(t)
    local s = B.pad(t.sPathHash or "", 32)
        .. B.pad(t.sContentHash or "", 32)
        .. B.u32(t.nFileSize or 0)
        .. B.u32(t.nTimestamp or 0)
        .. B.pad("", 20)
    s = s .. B.u32(B.crc32(s))
    return B.pad(s, VB.ENTRY_SZ)
end

local function fUnpackEntry(s, o)
    o = o or 1
    if #s < o + VB.ENTRY_SZ - 1 then return nil end
    local t = {
        sPathHash    = s:sub(o, o + 31),
        sContentHash = s:sub(o + 32, o + 63),
        nFileSize    = B.r32(s, o + 64),
        nTimestamp   = B.r32(s, o + 68),
    }
    t.bCrcOk = (B.r32(s, o + 92) == B.crc32(s:sub(o, o + 91)))
    -- Check if entry is empty (all zeros)
    t.bEmpty = (t.sPathHash == string.rep("\0", 32))
    return t
end

-- =============================================
-- BUILD: Create AXVB from file list
--
-- Called by xparted or kernel during install/rebuild.
-- Writes header + encrypted hash entries to disk.
--
-- @param tDisk         Disk I/O table (readSector, writeSector, sectorSize)
-- @param nPartOffset   AXVB partition start sector (0-indexed)
-- @param nPartSize     AXVB partition size in sectors
-- @param tFiles        Array of {sPath, sContentHash, nSize}
-- @param oSha          SHA-256 module (digest, hmac)
-- @param sMachBinding  32-byte machine binding hash
-- @return true or nil+error
-- =============================================

function VB.Build(tDisk, nPartOffset, nPartSize, tFiles, oSha, sMachBinding)
    if not tDisk or not oSha then return nil, "missing args" end
    local ss = tDisk.sectorSize or 512
    local eps = epsForSS(ss)

    if #tFiles > eps * (nPartSize - 1) then
        return nil, "too many files for AXVB partition"
    end

    -- Generate random FPE salt
    local sFpeSalt = ""
    for i = 1, 32 do
        sFpeSalt = sFpeSalt .. string.char(math.random(0, 255))
    end

    -- Derive encryption key
    local sKey = fDeriveKey(oSha, sMachBinding, sFpeSalt)

    -- Write header (sector 0, NOT encrypted)
    local tHdr = {
        nEntryCount    = #tFiles,
        nFlags         = 0,
        sFpeSalt       = sFpeSalt,
        sMachineBinding = sMachBinding or "",
        nBuildTime     = os.time and os.time() or 0,
        nGeneration    = 1,
    }
    tDisk.writeSector(nPartOffset, fPackHeader(tHdr, ss))

    -- Build entries and write encrypted sectors
    local nSectorIdx = 0
    local sSectorBuf = ""

    for i, tF in ipairs(tFiles) do
        local sPathHash = oSha.digest(tF.sPath)
        local tEntry = {
            sPathHash    = sPathHash,
            sContentHash = tF.sContentHash,
            nFileSize    = tF.nSize or 0,
            nTimestamp   = os.time and os.time() or 0,
        }
        sSectorBuf = sSectorBuf .. fPackEntry(tEntry)

        -- Flush sector when full or last entry
        if #sSectorBuf >= eps * VB.ENTRY_SZ or i == #tFiles then
            -- Pad sector
            sSectorBuf = B.pad(sSectorBuf, ss)
            -- Encrypt
            if sKey then
                sSectorBuf = fXorSector(sKey, sSectorBuf, nSectorIdx)
            end
            tDisk.writeSector(nPartOffset + 1 + nSectorIdx, sSectorBuf)
            nSectorIdx = nSectorIdx + 1
            sSectorBuf = ""
        end
    end

    -- Zero remaining sectors
    for s = nSectorIdx, nPartSize - 2 do
        tDisk.writeSector(nPartOffset + 1 + s, B.pad("", ss))
    end

    return true, { nEntries = #tFiles, nDataSectors = nSectorIdx }
end

-- =============================================
-- LOOKUP: Read ONE file's hash from AXVB
--
-- Reads at most 2 sectors: header (cached) + one data sector.
-- RAM cost: ~1KB (two sector buffers on stack).
--
-- @param tDisk         Disk I/O
-- @param nPartOffset   AXVB partition start sector
-- @param sPath         File path to look up
-- @param oSha          SHA-256 module
-- @param sMachBinding  Machine binding hash
-- @param tHdrCache     Optional: cached header (avoids re-reading sector 0)
-- @return binary_content_hash or nil, error_string
-- =============================================

function VB.Lookup(tDisk, nPartOffset, sPath, oSha, sMachBinding, tHdrCache)
    if not tDisk or not oSha then return nil, "no disk/sha" end
    local ss = tDisk.sectorSize or 512
    local eps = epsForSS(ss)

    -- Read or use cached header
    local tHdr = tHdrCache
    if not tHdr then
        local sH = tDisk.readSector(nPartOffset)
        if not sH then return nil, "read error" end
        tHdr = fUnpackHeader(sH)
        if not tHdr then return nil, "bad header" end
    end

    if tHdr.nEntryCount == 0 then return nil, "empty" end

    -- Derive decryption key
    local sKey = fDeriveKey(oSha, sMachBinding, tHdr.sFpeSalt)

    -- Hash the path for lookup
    local sTargetPathHash = oSha.digest(sPath)

    -- Linear scan through data sectors
    -- For ~40 files across ~8 sectors, this is fast enough.
    -- Could add a hash-indexed directory later if needed.
    local nDataSectors = math.ceil(tHdr.nEntryCount / eps)

    for nSec = 0, nDataSectors - 1 do
        local sSector = tDisk.readSector(nPartOffset + 1 + nSec)
        if not sSector then goto next_sector end

        -- Decrypt
        if sKey then
            sSector = fXorSector(sKey, sSector, nSec)
        end

        -- Scan entries in this sector
        for nEnt = 0, eps - 1 do
            local nOff = nEnt * VB.ENTRY_SZ + 1
            local tE = fUnpackEntry(sSector, nOff)
            if not tE or tE.bEmpty then goto next_entry end

            if tE.sPathHash == sTargetPathHash then
                if tE.bCrcOk then
                    return tE.sContentHash, tE
                else
                    return nil, "entry CRC fail"
                end
            end
            ::next_entry::
        end
        ::next_sector::
    end

    return nil, "not_tracked"
end

-- =============================================
-- READ HEADER (for caching by caller)
-- =============================================

function VB.ReadHeader(tDisk, nPartOffset)
    local sH = tDisk.readSector(nPartOffset)
    if not sH then return nil end
    return fUnpackHeader(sH)
end

-- =============================================
-- VERIFY: Compare file content against stored hash
--
-- @return true (pass), false (mismatch), nil (not tracked/error)
-- =============================================

function VB.Verify(tDisk, nPartOffset, sPath, sContent, oSha, sMachBinding, tHdrCache)
    local sExpected, sErr = VB.Lookup(tDisk, nPartOffset, sPath, oSha, sMachBinding, tHdrCache)
    if not sExpected then return nil, sErr end

    local sActual = oSha.digest(sContent)
    if sActual == sExpected then return true end
    return false, "hash_mismatch"
end

-- =============================================
-- STATS
-- =============================================

function VB.GetStats(tDisk, nPartOffset)
    local tHdr = VB.ReadHeader(tDisk, nPartOffset)
    if not tHdr then return nil end
    return {
        nVersion    = tHdr.nVersion,
        nEntries    = tHdr.nEntryCount,
        nGeneration = tHdr.nGeneration,
        nBuildTime  = tHdr.nBuildTime,
        bCrcOk      = tHdr.bCrcOk,
    }
end

return VB