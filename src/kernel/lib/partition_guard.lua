--
-- /lib/partition_guard.lua
-- AxisOS Partition Guard — Ring-Gated Sector Access Control
--
-- Loaded by the kernel at Ring 0 boot time.
-- Builds a protected-sector-range table from the RDB,
-- then provides wrapProxy() to create filtered drive proxies
-- for Ring > 0 callers. Protected partitions are invisible
-- and untouchable from user-mode code.
--
-- The guard covers:
--   • RDB header + partition entry sectors (0..MAX_PARTS)
--   • All partitions flagged PF_SYSTEM
--   • All partitions with fsType in the system-set
--     (AXKBL, AXKSR, AXOLR, AXEFI, AXVB, AXBC, AXSN, AXRC)
--
-- Protected reads return nil (appears as I/O error).
-- Protected writes are silently dropped (appears as success).
--

local PG = {}

PG.VERSION = "1.0.0"

-- System fsTypes that are ALWAYS protected regardless of flags
local SYSTEM_FS_TYPES = {
    [0x41584B42] = true,  -- AXKBL
    [0x41584B53] = true,  -- AXKSR
    [0x41584F4C] = true,  -- AXOLR
    [0x41584546] = true,  -- AXEFI
    [0x41585642] = true,  -- AXVB  (Verified Boot)
    [0x41584243] = true,  -- AXBC  (Boot Control)
    [0x4158534E] = true,  -- AXSN  (Snapshot)
    [0x41585243] = true,  -- AXRC  (Recovery)
    [0x41584D44] = true,  -- AXMD  (Metadata)
}

-- =============================================
-- RANGE TABLE
-- Each entry: {nStart, nEnd, sLabel}
-- Sector numbers are 0-indexed (RDB convention).
-- OC drive API is 1-indexed, so callers convert.
-- =============================================

local g_tRanges     = {}
local g_nRangeCount = 0
local g_fLog        = function() end

function PG.Initialize(tCfg)
    g_fLog = tCfg.fLog or g_fLog
    g_tRanges = {}
    g_nRangeCount = 0

    -- Always protect the RDB area (sectors 0..MAX_PARTS)
    local MAX_PARTS = tCfg.nMaxParts or 16
    PG.AddRange(0, MAX_PARTS, "RDB_HEADER")

    g_fLog("[GUARD] Partition Guard initialized")
    return true
end

function PG.AddRange(nStart, nEnd, sLabel)
    g_nRangeCount = g_nRangeCount + 1
    g_tRanges[g_nRangeCount] = {nStart, nEnd, sLabel or "?"}
end

--- Scan an RDB structure and add all system partitions.
-- @param tRdb  Parsed RDB table (from rdb.lua RDB.read())
function PG.ScanRdb(tRdb)
    if not tRdb or not tRdb.partitions then return 0 end
    local nAdded = 0

    for i, p in ipairs(tRdb.partitions) do
        local bProtect = false
        local sReason = ""

        -- Check fsType
        if SYSTEM_FS_TYPES[p.fsType] then
            bProtect = true
            sReason = "fsType"
        end

        -- Check PF_SYSTEM flag (0x10)
        if not bProtect and bit32.band(p.flags or 0, 0x10) ~= 0 then
            bProtect = true
            sReason = "PF_SYSTEM"
        end

        -- Check PF_HIDDEN_FS flag (0x08) — hidden partitions are system
        if not bProtect and bit32.band(p.flags or 0, 0x08) ~= 0 then
            bProtect = true
            sReason = "PF_HIDDEN"
        end

        if bProtect then
            local nStart = p.startSector
            local nEnd   = p.startSector + p.sizeSectors - 1
            PG.AddRange(nStart, nEnd, (p.deviceName or "P"..i) .. " (" .. sReason .. ")")
            nAdded = nAdded + 1
            g_fLog(string.format(
                "[GUARD] Protected: %s sectors %d-%d (%s)",
                p.deviceName or "?", nStart, nEnd, sReason))
        end
    end

    g_fLog(string.format(
        "[GUARD] %d partition(s) protected, %d range(s) total",
        nAdded, g_nRangeCount))
    return nAdded
end

--- Check if a 0-indexed sector number falls within any protected range.
-- Uses a linear scan (fast enough for <20 ranges).
-- @param nSector 0-indexed sector number
-- @return true if protected, false otherwise
function PG.IsProtected(nSector)
    for i = 1, g_nRangeCount do
        local r = g_tRanges[i]
        if nSector >= r[1] and nSector <= r[2] then
            return true, r[3]
        end
    end
    return false
end

--- Create a filtered drive proxy that blocks access to protected sectors.
-- Methods other than readSector/writeSector pass through unchanged.
-- Protected reads return nil (I/O error appearance).
-- Protected writes silently succeed (data discarded).
--
-- @param oRealProxy  The actual OC drive component proxy
-- @return table      Filtered proxy with identical API
function PG.WrapProxy(oRealProxy)
    if not oRealProxy then return nil end

    -- Cache frequently-called methods for speed
    local fRealRead  = oRealProxy.readSector
    local fRealWrite = oRealProxy.writeSector

    local tFiltered = {}

    -- Copy all non-sector methods verbatim
    -- (getCapacity, getSectorSize, getPlatterCount, getLabel, etc.)
    local tPassthrough = {
        "getCapacity", "getSectorSize", "getPlatterCount",
        "getLabel", "setLabel", "address", "type",
    }
    for _, sMethod in ipairs(tPassthrough) do
        if oRealProxy[sMethod] then
            tFiltered[sMethod] = oRealProxy[sMethod]
        end
    end

    -- Preserve component identity
    tFiltered.address = oRealProxy.address
    tFiltered.type    = oRealProxy.type or "drive"

    -- Filtered readSector: OC uses 1-indexed sectors
    -- Our ranges are 0-indexed, so subtract 1 for the check.
    tFiltered.readSector = function(nOcSector)
        local nZeroSector = nOcSector - 1
        if PG.IsProtected(nZeroSector) then
            return nil  -- appears as read error
        end
        return fRealRead(nOcSector)
    end

    -- Filtered writeSector: silently discard writes to protected sectors
    tFiltered.writeSector = function(nOcSector, sData)
        local nZeroSector = nOcSector - 1
        if PG.IsProtected(nZeroSector) then
            return true  -- pretend success (data discarded)
        end
        return fRealWrite(nOcSector, sData)
    end

    -- Freeze to prevent method replacement by ring 2 drivers
    setmetatable(tFiltered, {
        __newindex = function()
            error("SECURITY: Drive proxy is read-only", 2)
        end,
        __metatable = "partition_guard",
    })

    return tFiltered
end

--- Get diagnostic info about current protection state.
function PG.GetStats()
    local tResult = {
        nRangeCount     = g_nRangeCount,
        tRanges         = {},
        nProtectedTotal = 0,
    }
    for i = 1, g_nRangeCount do
        local r = g_tRanges[i]
        local nSize = r[2] - r[1] + 1
        tResult.tRanges[i] = {
            nStart = r[1], nEnd = r[2],
            nSize = nSize, sLabel = r[3],
        }
        tResult.nProtectedTotal = tResult.nProtectedTotal + nSize
    end
    return tResult
end

return PG