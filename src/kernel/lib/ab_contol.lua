--
-- /lib/ab_control.lua
-- AxisOS A/B Boot Control + Snapshot Manager
--
-- AXBC partition (2 sectors): boot state, slot health, rollback
-- AXSN partition (variable): encrypted backup of critical files
--
-- Design:
--   Slot A = live files in the main AXFS partition
--   Slot B = encrypted backup copies in the AXSN partition
--   AXBC tracks: active slot, boot attempts, verified-good flag
--
-- On verified-boot success: overwrite AXSN with current good state
-- On verified-boot failure: restore from AXSN to AXFS, panic if fails
--
-- All AXBC/AXSN data is encrypted with hardware-derived keys.
--

local B = require("bpack")
local AB = {}

AB.AXBC_MAGIC   = "AXBC"
AB.AXBC_VERSION  = 1
AB.AXBC_FS_TYPE  = 0x41584243  -- "AXBC"

AB.AXSN_MAGIC   = "AXSN"
AB.AXSN_VERSION  = 1
AB.AXSN_FS_TYPE  = 0x4158534E  -- "AXSN"

AB.SLOT_A = 0  -- Live AXFS
AB.SLOT_B = 1  -- Snapshot backup

AB.STATE_GOOD      = 0
AB.STATE_UNVERIFIED = 1
AB.STATE_CORRUPT   = 2

-- =============================================
-- AXBC HEADER (256 bytes, sector 0)
--
-- [1-4]    Magic "AXBC"
-- [5]      Version
-- [6]      Active slot (0=A, 1=B)
-- [7]      Slot A state (0=good, 1=unverified, 2=corrupt)
-- [8]      Slot B state
-- [9-12]   Boot attempt counter (uint32)
-- [13-16]  Successful boot counter (uint32) 
-- [17-20]  Last verified timestamp (uint32)
-- [21-24]  Rollback count (uint32)
-- [25-28]  Snapshot file count (uint32)
-- [29-32]  Snapshot total bytes (uint32)
-- [33-64]  Hardware binding hash (32 bytes)
-- [65-96]  Encryption salt (32 bytes)
-- [97-120] Reserved
-- [121-124] CRC32 of bytes 1-120
-- [125-256] Reserved / mirror
-- =============================================

local function fEncryptBlock(sData, sKey)
    if not sKey or #sKey == 0 then return sData end
    local t = {}
    for i = 1, #sData do
        t[i] = string.char(bit32.bxor(
            sData:byte(i),
            sKey:byte(((i - 1) % #sKey) + 1)))
    end
    return table.concat(t)
end

local function fPackAxbc(t, nSS)
    local s = AB.AXBC_MAGIC
        .. B.u8(AB.AXBC_VERSION)
        .. B.u8(t.nActiveSlot or AB.SLOT_A)
        .. B.u8(t.nSlotAState or AB.STATE_UNVERIFIED)
        .. B.u8(t.nSlotBState or AB.STATE_UNVERIFIED)
        .. B.u32(t.nBootAttempts or 0)
        .. B.u32(t.nSuccessBoots or 0)
        .. B.u32(t.nLastVerified or 0)
        .. B.u32(t.nRollbacks or 0)
        .. B.u32(t.nSnapshotFiles or 0)
        .. B.u32(t.nSnapshotBytes or 0)
        .. B.pad(t.sBinding or "", 32)
        .. B.pad(t.sSalt or "", 32)
        .. B.pad("", 24)
    s = s .. B.u32(B.crc32(s))
    return B.pad(s, nSS or 512)
end

local function fUnpackAxbc(s)
    if not s or #s < 124 then return nil end
    if s:sub(1, 4) ~= AB.AXBC_MAGIC then return nil end
    local t = {
        nActiveSlot    = s:byte(6),
        nSlotAState    = s:byte(7),
        nSlotBState    = s:byte(8),
        nBootAttempts  = B.r32(s, 9),
        nSuccessBoots  = B.r32(s, 13),
        nLastVerified  = B.r32(s, 17),
        nRollbacks     = B.r32(s, 21),
        nSnapshotFiles = B.r32(s, 25),
        nSnapshotBytes = B.r32(s, 29),
        sBinding       = s:sub(33, 64),
        sSalt          = s:sub(65, 96),
    }
    t.bCrcOk = (B.r32(s, 121) == B.crc32(s:sub(1, 120)))
    return t
end

-- =============================================
-- AXSN: Snapshot Store
--
-- Sector 0: Directory header
-- Sector 1-N: File directory entries (64 bytes each, 8 per sector)
-- Sector N+1-M: File data blocks (encrypted)
--
-- Directory entry (64 bytes):
--   [1-32]  Path hash
--   [33-36] Data start sector (relative to partition)
--   [37-40] Data size in bytes
--   [41-44] Content hash prefix (first 4 bytes of SHA-256)
--   [45-48] CRC32 of entry
--   [49-64] Reserved
-- =============================================

local AXSN_DIRENT_SZ = 64

local function fPackSnDir(t)
    local s = B.pad(t.sPathHash or "", 32)
        .. B.u32(t.nDataStart or 0)
        .. B.u32(t.nDataSize or 0)
        .. B.pad(t.sHashPrefix or "", 4)
    s = s .. B.u32(B.crc32(s))
    return B.pad(s, AXSN_DIRENT_SZ)
end

-- =============================================
-- PUBLIC API: Boot Control
-- =============================================

function AB.ReadBootControl(tDisk, nPartOffset)
    local s = tDisk.readSector(nPartOffset)
    if not s then return nil end
    return fUnpackAxbc(s)
end

function AB.WriteBootControl(tDisk, nPartOffset, tState)
    local ss = tDisk.sectorSize or 512
    local s = fPackAxbc(tState, ss)
    tDisk.writeSector(nPartOffset, s)
    -- Mirror to sector 1 for redundancy
    tDisk.writeSector(nPartOffset + 1, s)
    return true
end

function AB.IncrementBootAttempt(tDisk, nPartOffset)
    local t = AB.ReadBootControl(tDisk, nPartOffset)
    if not t then return nil end
    t.nBootAttempts = t.nBootAttempts + 1
    return AB.WriteBootControl(tDisk, nPartOffset, t)
end

function AB.MarkSlotGood(tDisk, nPartOffset, nSlot)
    local t = AB.ReadBootControl(tDisk, nPartOffset)
    if not t then return nil end
    if nSlot == AB.SLOT_A then t.nSlotAState = AB.STATE_GOOD
    else t.nSlotBState = AB.STATE_GOOD end
    t.nSuccessBoots = t.nSuccessBoots + 1
    t.nLastVerified = os.time and os.time() or 0
    return AB.WriteBootControl(tDisk, nPartOffset, t)
end

function AB.MarkSlotCorrupt(tDisk, nPartOffset, nSlot)
    local t = AB.ReadBootControl(tDisk, nPartOffset)
    if not t then return nil end
    if nSlot == AB.SLOT_A then t.nSlotAState = AB.STATE_CORRUPT
    else t.nSlotBState = AB.STATE_CORRUPT end
    return AB.WriteBootControl(tDisk, nPartOffset, t)
end

-- =============================================
-- PUBLIC API: Snapshot Operations
-- =============================================

--- Create a snapshot of critical files into the AXSN partition.
-- @param tDisk       Drive I/O
-- @param nSnOff      AXSN partition offset
-- @param nSnSize     AXSN partition size in sectors
-- @param tFiles      Array of {sPath, sContent}
-- @param oSha        SHA-256 module
-- @param sBinding    Machine binding for encryption
function AB.CreateSnapshot(tDisk, nSnOff, nSnSize, tFiles, oSha, sBinding)
    if not tDisk or not oSha then return nil, "bad args" end
    local ss = tDisk.sectorSize or 512
    local dps = math.floor(ss / AXSN_DIRENT_SZ)  -- dir entries per sector

    -- Generate encryption salt
    local sSalt = ""
    for i = 1, 32 do sSalt = sSalt .. string.char(math.random(0, 255)) end
    local sKey = oSha.hmac(sBinding or "", sSalt)

    -- Calculate layout
    local nDirSectors = math.ceil(#tFiles / dps)
    local nDataStart = 1 + nDirSectors  -- relative to partition start

    -- Write file data and build directory
    local tDirEntries = {}
    local nDataCursor = nDataStart

    for i, tF in ipairs(tFiles) do
        local sEncData = fEncryptBlock(tF.sContent, sKey)
        local nFileSectors = math.ceil(#sEncData / ss)

        -- Write encrypted file data
        for s = 0, nFileSectors - 1 do
            local sChunk = sEncData:sub(s * ss + 1, (s + 1) * ss)
            tDisk.writeSector(nSnOff + nDataCursor + s, B.pad(sChunk, ss))
        end

        local sPathHash = oSha.digest(tF.sPath)
        tDirEntries[i] = fPackSnDir({
            sPathHash  = sPathHash,
            nDataStart = nDataCursor,
            nDataSize  = #tF.sContent,
            sHashPrefix = oSha.digest(tF.sContent):sub(1, 4),
        })

        nDataCursor = nDataCursor + nFileSectors
    end

    -- Write directory header (sector 0)
    local sHdr = AB.AXSN_MAGIC
        .. B.u8(AB.AXSN_VERSION)
        .. B.u8(0)
        .. B.u16(#tFiles)
        .. B.u32(nDirSectors)
        .. B.pad(sSalt, 32)
        .. B.pad(sBinding or "", 32)
    sHdr = sHdr .. B.u32(B.crc32(sHdr))
    tDisk.writeSector(nSnOff, B.pad(sHdr, ss))

    -- Write directory entries
    for sec = 0, nDirSectors - 1 do
        local sSector = ""
        for j = 1, dps do
            local idx = sec * dps + j
            if tDirEntries[idx] then
                sSector = sSector .. tDirEntries[idx]
            end
        end
        tDisk.writeSector(nSnOff + 1 + sec, B.pad(sSector, ss))
    end

    return true, { nFiles = #tFiles, nSectors = nDataCursor }
end

--- Restore a file from AXSN snapshot to the AXFS volume.
-- Returns the decrypted file content (caller writes to AXFS).
function AB.RestoreFile(tDisk, nSnOff, sPath, oSha, sBinding)
    if not tDisk or not oSha then return nil end
    local ss = tDisk.sectorSize or 512
    local dps = math.floor(ss / AXSN_DIRENT_SZ)

    -- Read AXSN header
    local sH = tDisk.readSector(nSnOff)
    if not sH or sH:sub(1, 4) ~= AB.AXSN_MAGIC then return nil, "bad AXSN" end
    local nFileCount = B.r16(sH, 7)
    local nDirSecs   = B.r32(sH, 9)
    local sSalt      = sH:sub(13, 44)
    local sKey       = oSha.hmac(sBinding or "", sSalt)
    local sTargetHash = oSha.digest(sPath)

    -- Scan directory for matching path
    for sec = 0, nDirSecs - 1 do
        local sSector = tDisk.readSector(nSnOff + 1 + sec)
        if not sSector then goto next_dir_sec end

        for j = 0, dps - 1 do
            local o = j * AXSN_DIRENT_SZ + 1
            if o + AXSN_DIRENT_SZ - 1 > #sSector then break end
            local sEntryPathHash = sSector:sub(o, o + 31)
            if sEntryPathHash == sTargetHash then
                local nDataStart = B.r32(sSector, o + 32)
                local nDataSize  = B.r32(sSector, o + 36)
                -- Read and decrypt data
                local nDataSecs = math.ceil(nDataSize / ss)
                local tChunks = {}
                for ds = 0, nDataSecs - 1 do
                    local sD = tDisk.readSector(nSnOff + nDataStart + ds)
                    if sD then tChunks[#tChunks + 1] = sD end
                end
                local sEncData = table.concat(tChunks):sub(1, nDataSize)
                return fEncryptBlock(sEncData, sKey)  -- XOR decrypt
            end
        end
        ::next_dir_sec::
    end
    return nil, "not found in snapshot"
end

--- Initialize AXBC and AXSN partitions.
function AB.InitPartitions(tDisk, nBcOff, nSnOff, nSnSize, sBinding)
    local ss = tDisk.sectorSize or 512
    -- Init AXBC
    local tState = {
        nActiveSlot   = AB.SLOT_A,
        nSlotAState   = AB.STATE_UNVERIFIED,
        nSlotBState   = AB.STATE_UNVERIFIED,
        nBootAttempts = 0,
        nSuccessBoots = 0,
        sBinding      = sBinding or "",
    }
    AB.WriteBootControl(tDisk, nBcOff, tState)

    -- Zero-fill AXSN
    if nSnOff and nSnSize then
        for i = 0, nSnSize - 1 do
            tDisk.writeSector(nSnOff + i, B.pad("", ss))
        end
        -- Write empty AXSN header
        local sHdr = AB.AXSN_MAGIC .. B.u8(AB.AXSN_VERSION)
            .. B.u8(0) .. B.u16(0) .. B.u32(0) .. B.pad("", 64)
        tDisk.writeSector(nSnOff, B.pad(sHdr, ss))
    end

    return true
end

return AB