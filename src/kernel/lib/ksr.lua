--
-- /lib/ksr.lua
-- Kernel State Region — On-Disk TPM PCR Bank
--
-- Append-only measurement log. Monotonic boot counter.
-- Quarantine records live HERE, not just in registry.
--
-- RDB partition type: FS_AXKSR = 0x41584B53 ("AXKS")
-- Flags: PF_HIDDEN_FS | PF_SYSTEM
--
-- RAM cost: 0 persistent, ~512B peak per extend
--

local B = require("bpack")
local KSR = {}

KSR.MAGIC   = "AXKS"
KSR.VERSION = 1
KSR.FS_TYPE = 0x41584B53

KSR.REC_BOOT       = 1
KSR.REC_PATCHGUARD = 2
KSR.REC_QUARANTINE = 3
KSR.REC_CONFIG     = 4

KSR.HDR_SZ = 56
KSR.DEFAULT_SIZE = 96
KSR.REC_SZ       = 64

local g_sKsrKey = nil

local function fGetSha()
    local ok, m = pcall(require, "sha256")
    return ok and m or nil
end

local function fHash(s)
    local m = fGetSha()
    if m then return m.digest(s) end
    local c = B.crc32(s)
    local t = {}
    for i = 0, 7 do c = B.crc32(B.u32(c)..B.u32(i)); t[i+1] = B.u32(c) end
    return table.concat(t)
end

-- =============================================
-- HEADER: 56 bytes at partition offset 0
-- =============================================

local function fPackHdr(t)
    local s = KSR.MAGIC
        .. B.u8(KSR.VERSION)
        .. B.u8(math.min(255, t.nCount or 0))
        .. B.u16(t.nNextOff or KSR.HDR_SZ)
        .. B.u32(t.nBootCtr or 0)
        .. B.u32(t.nLastGood or 0)
        .. B.pad(t.sAggregate or "", 32)
    s = s .. B.u32(B.crc32(s))
    return B.pad(s, KSR.HDR_SZ)
end

local function fUnpackHdr(s)
    if not s or #s < KSR.HDR_SZ then return nil end
    if s:sub(1, 4) ~= KSR.MAGIC then return nil end
    local t = {
        nCount     = s:byte(6),
        nNextOff   = B.r16(s, 7),
        nBootCtr   = B.r32(s, 9),
        nLastGood  = B.r32(s, 13),
        sAggregate = s:sub(17, 48),
    }
    t.bCrcOk = (B.r32(s, 49) == B.crc32(s:sub(1, 48)))
    return t
end

-- =============================================
-- RECORD: 64 bytes
-- =============================================

local function fPackRec(t)
    local s = B.u8(t.nType or 0)
        .. B.u8(0) .. B.u16(0)
        .. B.u32(t.nBootCtr or 0)
        .. B.u32(t.nTimestamp or 0)
        .. B.pad(t.sMeasure or "", 32)
        .. B.pad(t.sPrev or "", 4)
        .. B.pad(t.sExtra or "", 12)
    s = s .. B.u32(B.crc32(s))
    return B.pad(s, KSR.REC_SZ)
end

local function fUnpackRec(s, o)
    o = o or 1
    if #s < o + KSR.REC_SZ - 1 then return nil end
    return {
        nType    = s:byte(o),
        nBootCtr = B.r32(s, o + 4),
        nTs      = B.r32(s, o + 8),
        sMeasure = s:sub(o + 12, o + 43),
        sPrev    = s:sub(o + 44, o + 47),
        sExtra   = s:sub(o + 48, o + 59),
        bCrcOk   = (B.r32(s, o + 60) == B.crc32(s:sub(o, o + 59))),
    }
end

-- =============================================
-- SECTOR-BASED I/O (RDB partition)
-- =============================================


function KSR.SetEncryptionKey(sKey)
    g_sKsrKey = sKey
end

local function fCryptRecord(sRec)
    if not g_sKsrKey or #g_sKsrKey == 0 then return sRec end
    local t = {}
    for i = 1, #sRec do
        t[i] = string.char(bit32.bxor(
            sRec:byte(i),
            g_sKsrKey:byte(((i - 1) % #g_sKsrKey) + 1)))
    end
    return table.concat(t)
end

function KSR.ReadHeader(tDisk, nOff)
    local s = tDisk.readSector(nOff)
    return s and fUnpackHdr(s)
end

function KSR.Init(tDisk, nOff, nSize)
    local ss = tDisk.sectorSize or 512
    for i = 0, (nSize or 4) - 1 do
        tDisk.writeSector(nOff + i, B.pad("", ss))
    end
    local sH = fPackHdr({ nCount = 0, nNextOff = KSR.HDR_SZ,
        nBootCtr = 0, nLastGood = 0, sAggregate = string.rep("\0", 32) })
    local sS = sH .. B.pad("", ss - KSR.HDR_SZ)
    tDisk.writeSector(nOff, B.pad(sS, ss))
    return true
end

function KSR.Extend(tDisk, nOff, nSize, tMeas)
    local ss = tDisk.sectorSize or 512
    local tH = KSR.ReadHeader(tDisk, nOff)
    if not tH then
        KSR.Init(tDisk, nOff, nSize)
        tH = KSR.ReadHeader(tDisk, nOff)
        if not tH then return false end
    end

    local sRec = fPackRec({
        nType    = tMeas.nType or KSR.REC_BOOT,
        nBootCtr = tH.nBootCtr,
        nTimestamp = math.floor(
            (pcall(function() return raw_computer.uptime() end)
                and raw_computer.uptime() or os.clock()) * 100),
        sMeasure = tMeas.sMeasure or "",
        sPrev    = tH.sAggregate:sub(1, 4),
        sExtra   = tMeas.sExtra or "",
    })
    sRec = fCryptRecord(sRec)
    -- Calculate write position
    local nWO = tH.nNextOff
    local nSecIdx = math.floor(nWO / ss)
    local nInSec  = nWO % ss

    -- Wrap if out of bounds
    if nSecIdx >= (nSize or 4) then
        nSecIdx = 0; nInSec = KSR.HDR_SZ; nWO = KSR.HDR_SZ
    end

    -- Read-modify-write target sector
    local sS = tDisk.readSector(nOff + nSecIdx) or B.pad("", ss)
    sS = sS:sub(1, nInSec) .. sRec .. sS:sub(nInSec + KSR.REC_SZ + 1)
    tDisk.writeSector(nOff + nSecIdx, B.pad(sS, ss))

    -- Update header
    tH.nCount     = math.min(255, (tH.nCount or 0) + 1)
    tH.nNextOff   = nWO + KSR.REC_SZ
    tH.sAggregate = fHash(tH.sAggregate .. sRec)

    local sS0 = tDisk.readSector(nOff) or B.pad("", ss)
    sS0 = fPackHdr(tH) .. sS0:sub(KSR.HDR_SZ + 1)
    tDisk.writeSector(nOff, B.pad(sS0, ss))
    return true
end

-- =============================================
-- FILE-BASED FALLBACK (managed FS)
-- Same format, header + records in flat file
-- =============================================

function KSR.ReadHeaderFile(oFs, sPath)
    sPath = sPath or "/etc/.ksr.dat"
    local h = oFs.open(sPath, "r")
    if not h then return nil end
    local s = oFs.read(h, KSR.HDR_SZ)
    oFs.close(h)
    return s and fUnpackHdr(s)
end

function KSR.ExtendFile(oFs, sPath, tMeas)
    sPath = sPath or "/etc/.ksr.dat"
    -- Read existing header
    local tH = KSR.ReadHeaderFile(oFs, sPath)
    if not tH then
        -- Create new file with empty header
        local hW = oFs.open(sPath, "w")
        if not hW then return false end
        oFs.write(hW, fPackHdr({
            nCount = 0, nNextOff = KSR.HDR_SZ,
            nBootCtr = 0, nLastGood = 0,
            sAggregate = string.rep("\0", 32),
        }))
        oFs.close(hW)
        tH = KSR.ReadHeaderFile(oFs, sPath)
        if not tH then return false end
    end

    local sRec = fPackRec({
        nType    = tMeas.nType or KSR.REC_BOOT,
        nBootCtr = tH.nBootCtr,
        nTimestamp = math.floor((pcall(function() return raw_computer.uptime() end)
            and raw_computer.uptime() or os.clock()) * 100),
        sMeasure = tMeas.sMeasure or "",
        sPrev    = tH.sAggregate:sub(1, 4),
        sExtra   = tMeas.sExtra or "",
    })

    -- Append record
    local hA = oFs.open(sPath, "a")
    if hA then oFs.write(hA, sRec); oFs.close(hA) end

    -- Update header (rewrite file start)
    tH.nCount     = math.min(255, (tH.nCount or 0) + 1)
    tH.nNextOff   = KSR.HDR_SZ + tH.nCount * KSR.REC_SZ
    tH.sAggregate = fHash(tH.sAggregate .. sRec)

    -- Read entire file, patch header, rewrite
    local hR = oFs.open(sPath, "r")
    if not hR then return false end
    local tC = {}
    while true do local c = oFs.read(hR, 4096); if not c then break end; tC[#tC+1] = c end
    oFs.close(hR)
    local sAll = table.concat(tC)
    sAll = fPackHdr(tH) .. sAll:sub(KSR.HDR_SZ + 1)
    local hW = oFs.open(sPath, "w")
    if hW then oFs.write(hW, sAll); oFs.close(hW) end

    return true
end

-- =============================================
-- HIGH-LEVEL MEASUREMENT HELPERS
-- =============================================


function KSR.IncrementBootCounter(tIO)
    local tH
    if tIO.readSector then tH = KSR.ReadHeader(tIO, tIO._off or 0)
    else tH = KSR.ReadHeaderFile(tIO._fs, tIO._path) end
    if not tH then return 1 end
    tH.nBootCtr  = tH.nBootCtr + 1
    tH.nLastGood = tH.nBootCtr
    -- Rewrite header with new counter
    if tIO.readSector then
        local ss = tIO.sectorSize or 512
        local sS = tIO.readSector(tIO._off or 0) or B.pad("", ss)
        sS = fPackHdr(tH) .. sS:sub(KSR.HDR_SZ + 1)
        tIO.writeSector(tIO._off or 0, B.pad(sS, ss))
    end
    return tH.nBootCtr
end

function KSR.ExtendBoot(tIO, sKernelHash, sCompFP)
    local m = fHash((sKernelHash or "") .. "|" .. (sCompFP or ""))
    local tMeas = {
        nType   = KSR.REC_BOOT,
        sMeasure = m,
        sExtra  = B.pad(sKernelHash and sKernelHash:sub(1, 8) or "", 12),
    }
    if tIO.readSector then
        return KSR.Extend(tIO, tIO._off or 0, tIO._size or 4, tMeas)
    else
        return KSR.ExtendFile(tIO._fs, tIO._path, tMeas)
    end
end

function KSR.ExtendPatchGuard(tIO, bArmed, nChecks)
    local tMeas = {
        nType    = KSR.REC_PATCHGUARD,
        sMeasure = fHash("PG:" .. tostring(bArmed) .. ":" .. tostring(nChecks)),
        sExtra   = B.u8(bArmed and 1 or 0) .. B.pad("", 3) .. B.u32(nChecks or 0) .. B.pad("", 4),
    }
    if tIO.readSector then
        return KSR.Extend(tIO, tIO._off or 0, tIO._size or 4, tMeas)
    else
        return KSR.ExtendFile(tIO._fs, tIO._path, tMeas)
    end
end

function KSR.ExtendQuarantine(tIO, sDrvName, nFaults)
    local tMeas = {
        nType    = KSR.REC_QUARANTINE,
        sMeasure = fHash("Q:" .. (sDrvName or "?")),
        sExtra   = B.u32(nFaults or 0) .. B.pad(sDrvName and sDrvName:sub(1, 8) or "", 8),
    }
    if tIO.readSector then
        return KSR.Extend(tIO, tIO._off or 0, tIO._size or 4, tMeas)
    else
        return KSR.ExtendFile(tIO._fs, tIO._path, tMeas)
    end
end

function KSR.GetBootCounter(tIO)
    local tH
    if tIO.readSector then tH = KSR.ReadHeader(tIO, tIO._off or 0)
    else tH = KSR.ReadHeaderFile(tIO._fs, tIO._path) end
    return tH and tH.nBootCtr or 0
end

function KSR.CheckRollback(tIO, nExpected)
    local n = KSR.GetBootCounter(tIO)
    if nExpected and n < nExpected then
        return false, n, "Boot counter decreased: rollback detected"
    end
    return true, n
end

--- Scan all quarantine records for a specific driver
function KSR.IsQuarantined(tIO, sDrvName)
    local sTarget = fHash("Q:" .. (sDrvName or "?"))
    -- Read backwards through sectors to find latest quarantine
    if tIO.readSector then
        local ss = tIO.sectorSize or 512
        local nOff = tIO._off or 0
        for sec = (tIO._size or 4) - 1, 0, -1 do
            local sS = tIO.readSector(nOff + sec)
            if sS then
                local nStart = (sec == 0) and KSR.HDR_SZ or 0
                local nRecsInSec = math.floor((ss - nStart) / KSR.REC_SZ)
                for i = nRecsInSec - 1, 0, -1 do
                    local tR = fUnpackRec(sS, nStart + i * KSR.REC_SZ + 1)
                    if tR and tR.nType == KSR.REC_QUARANTINE then
                        if tR.sMeasure:sub(1, 16) == sTarget:sub(1, 16) then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

return KSR