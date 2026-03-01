--
-- /lib/golden_image.lua
-- AxisOS Golden Image — Zero-RAM Critical File Reversion
--
-- AXFS path:
--   Boot → snapshot inode (extents, size, flags, inline) → ~80 B/file
--   Revert → write golden inode to inode table sector on disk
--
-- Managed FS path:
--   Boot → try to copy critical files to /etc/.golden/<hash>.bak
--   If disk full → fall back to distribution backups at /etc/.golden_<path>.bak
--   Revert → overwrite from shadow OR distribution backup (disk→disk)
--

local GI = {}

-- =============================================
-- STATE
-- =============================================

local g_tGoldenInodes   = {}   -- [sPath] → inode snapshot table (AXFS only)
local g_tGoldenShadows  = {}   -- [sPath] → shadow file path on disk (managed FS)
local g_bAxfsRoot        = false
local g_oAxfsVol         = nil
local g_oPrimitiveFs     = nil
local g_fLog             = function() end
local g_bInitialized     = false

local SHADOW_DIR = "/etc/.golden"
-- Distribution backups: shipped with the OS at /etc/.golden_<flattened_path>.bak
-- These are NOT modified at runtime and serve as last-resort reversion source.
local DIST_BACKUP_DIR = "/etc"

-- =============================================
-- HELPERS
-- =============================================

--- Convert a file path to the distribution backup filename.
-- /lib/preempt.lua → /etc/.golden_lib_preempt.lua.bak
local function fDistBackupPath(sPath)
    return DIST_BACKUP_DIR .. "/.golden_" .. sPath:gsub("/", "_") .. ".bak"
end

--- Convert a file path to the runtime shadow filename.
-- /lib/preempt.lua → /etc/.golden/_lib_preempt.lua.bak
local function fShadowPath(sPath)
    return SHADOW_DIR .. "/" .. sPath:gsub("/", "_") .. ".bak"
end

--- Check if a file exists on the raw filesystem.
local function fFileExists(sPath)
    if not g_oPrimitiveFs then return false end
    local h = g_oPrimitiveFs.open(sPath, "r")
    if h then g_oPrimitiveFs.close(h); return true end
    return false
end

-- =============================================
-- INITIALIZATION
-- =============================================

function GI.Initialize(tCfg)
    g_bAxfsRoot    = tCfg.bAxfsRoot or false
    g_oAxfsVol     = tCfg.oAxfsVol
    g_oPrimitiveFs = tCfg.oPrimitiveFs
    g_fLog         = tCfg.fLog or g_fLog

    if not g_oPrimitiveFs then
        g_fLog("[GOLDEN] No filesystem — cannot initialize")
        return false
    end

    g_fLog("[GOLDEN] Initializing golden image subsystem")
    g_fLog("[GOLDEN]   Root type: " .. (g_bAxfsRoot and "AXFS" or "managed"))

    g_bInitialized = true
    return true
end

-- =============================================
-- SNAPSHOT: Record golden state for one file
-- =============================================

function GI.SnapshotFile(sPath)
    if not g_bInitialized then return false, "not initialized" end

    if g_bAxfsRoot and g_oAxfsVol then
        -- AXFS PATH: store inode metadata only (~80 bytes)
        local tInode = g_oAxfsVol:stat(sPath)
        if not tInode then return false, "file not found: " .. sPath end

        local tSnap = {
            iType      = tInode.iType,
            mode       = tInode.mode,
            uid        = tInode.uid,
            gid        = tInode.gid,
            size       = tInode.size,
            ctime      = tInode.ctime,
            mtime      = tInode.mtime,
            links      = tInode.links,
            flags      = tInode.flags,
            nExtents   = tInode.nExtents,
            indirect   = tInode.indirect,
            inlineData = tInode.inlineData,
            extents    = {},
            inode      = tInode.inode,
        }
        if tInode.extents then
            for i, ext in ipairs(tInode.extents) do
                tSnap.extents[i] = { ext[1], ext[2] }
            end
        end

        if g_oAxfsVol.pinGoldenBlocks then
            g_oAxfsVol:pinGoldenBlocks(tSnap)
        end

        g_tGoldenInodes[sPath] = tSnap
        return true

    else
        -- MANAGED FS PATH
        -- Ensure shadow directory exists
        pcall(function() g_oPrimitiveFs.makeDirectory(SHADOW_DIR) end)

        -- Verify source file is readable
        local hSrc = g_oPrimitiveFs.open(sPath, "r")
        if not hSrc then return false, "cannot read: " .. sPath end

        -- Attempt to create runtime shadow copy
        local sShadow = fShadowPath(sPath)
        local hDst = g_oPrimitiveFs.open(sShadow, "w")

        if hDst then
            -- Stream copy: disk→disk, never holding full file in RAM
            while true do
                local sChunk = g_oPrimitiveFs.read(hSrc, 2048)
                if not sChunk then break end
                g_oPrimitiveFs.write(hDst, sChunk)
            end
            g_oPrimitiveFs.close(hSrc)
            g_oPrimitiveFs.close(hDst)
            g_tGoldenShadows[sPath] = sShadow
            return true
        end

        -- Shadow creation failed (disk full, permissions, etc.)
        -- *** FIX: ALWAYS close the source handle ***
        g_oPrimitiveFs.close(hSrc)

        -- FALLBACK: Check for distribution backup (ships with the OS)
        local sDistBackup = fDistBackupPath(sPath)
        if fFileExists(sDistBackup) then
            g_tGoldenShadows[sPath] = sDistBackup
            g_fLog("[GOLDEN] Shadow failed, using dist backup: " ..
                sPath:match("([^/]+)$") or sPath)
            return true
        end

        -- No shadow and no distribution backup — detection-only mode
        return false, "cannot create shadow: " .. sShadow
    end
end

-- =============================================
-- SNAPSHOT ALL
-- =============================================

function GI.SnapshotAll(tPaths)
    if not g_bInitialized then return 0, 0 end
    local nOk, nFail, nDistFallback = 0, 0, 0
    for _, sPath in ipairs(tPaths) do
        local bOk, sErr = GI.SnapshotFile(sPath)
        if bOk then
            nOk = nOk + 1
            -- Track distribution fallbacks for reporting
            local sShadow = g_tGoldenShadows[sPath]
            if sShadow and sShadow:find("/.golden_", 1, true) then
                nDistFallback = nDistFallback + 1
            end
        else
            nFail = nFail + 1
            g_fLog("[GOLDEN] Snapshot FAIL: " .. sPath .. " — " .. tostring(sErr))
        end
    end
    if nDistFallback > 0 then
        g_fLog(string.format(
            "[GOLDEN] Snapshot complete: %d OK (%d via dist backup), %d failed",
            nOk, nDistFallback, nFail))
    else
        g_fLog(string.format("[GOLDEN] Snapshot complete: %d OK, %d failed", nOk, nFail))
    end
    return nOk, nFail
end

-- =============================================
-- REVERT: Restore a file from golden image
-- =============================================

function GI.Revert(sPath)
    if not g_bInitialized then return false, "not initialized" end

    g_fLog("[GOLDEN] REVERTING: " .. sPath)

    if g_bAxfsRoot and g_oAxfsVol then
        -- AXFS PATH: write golden inode back to disk
        local tGolden = g_tGoldenInodes[sPath]
        if not tGolden then
            return false, "no golden snapshot for: " .. sPath
        end

        local nIno = g_oAxfsVol:resolve(sPath)
        if not nIno then
            return false, "file disappeared from filesystem: " .. sPath
        end

        g_oAxfsVol:wi(nIno, tGolden)
        g_oAxfsVol:_dirtyMeta()

        g_fLog("[GOLDEN] AXFS inode " .. nIno .. " reverted to golden state")
        return true

    else
        -- MANAGED FS PATH: restore from shadow or distribution backup
        local sShadow = g_tGoldenShadows[sPath]

        -- If no registered shadow, try distribution backup as last resort
        if not sShadow then
            local sDistBackup = fDistBackupPath(sPath)
            if fFileExists(sDistBackup) then
                sShadow = sDistBackup
                g_fLog("[GOLDEN] Using distribution backup for revert: " .. sPath)
            else
                return false, "no golden shadow or distribution backup for: " .. sPath
            end
        end

        -- Verify shadow/backup source still exists
        local hSrc = g_oPrimitiveFs.open(sShadow, "r")
        if not hSrc then
            -- Shadow was deleted — try distribution backup
            local sDistBackup = fDistBackupPath(sPath)
            if sShadow ~= sDistBackup and fFileExists(sDistBackup) then
                hSrc = g_oPrimitiveFs.open(sDistBackup, "r")
                if hSrc then
                    g_fLog("[GOLDEN] Shadow missing, using dist backup for: " .. sPath)
                end
            end
            if not hSrc then
                return false, "shadow file missing: " .. sShadow
            end
        end

        local hDst = g_oPrimitiveFs.open(sPath, "w")
        if not hDst then
            g_oPrimitiveFs.close(hSrc)
            return false, "cannot write target: " .. sPath
        end

        -- Stream copy: disk→disk
        while true do
            local sChunk = g_oPrimitiveFs.read(hSrc, 2048)
            if not sChunk then break end
            g_oPrimitiveFs.write(hDst, sChunk)
        end
        g_oPrimitiveFs.close(hSrc)
        g_oPrimitiveFs.close(hDst)

        g_fLog("[GOLDEN] Managed FS file reverted from: " .. sShadow)
        return true
    end
end

-- =============================================
-- QUERY
-- =============================================

function GI.HasGolden(sPath)
    if g_tGoldenInodes[sPath] then return true end
    if g_tGoldenShadows[sPath] then return true end
    -- Also check distribution backup (may not be registered but exists on disk)
    if g_oPrimitiveFs and fFileExists(fDistBackupPath(sPath)) then return true end
    return false
end

function GI.GetStats()
    local nAxfs, nManaged, nDist = 0, 0, 0
    for _ in pairs(g_tGoldenInodes) do nAxfs = nAxfs + 1 end
    for sPath, sShadow in pairs(g_tGoldenShadows) do
        nManaged = nManaged + 1
        if sShadow:find("/.golden_", 1, true) then
            nDist = nDist + 1
        end
    end
    return {
        nAxfsSnapshots     = nAxfs,
        nManagedShadows    = nManaged,
        nDistFallbacks     = nDist,
        bAxfsRoot          = g_bAxfsRoot,
        bInitialized       = g_bInitialized,
    }
end

return GI