--
-- /usr/commands/parted.lua
-- AxisOS AXFS Drive Manager — Interactive Shell
-- v2: @RDB::Partition extension display
--
-- Usage:
--   parted                       Scan for drives
--   parted <device>              Open device interactively
--   parted <device> install <p>  Direct install (non-interactive)
--

local fs  = require("filesystem")
local AX  = require("axfs_core")
local RDB = require("rdb")
local B   = require("bpack")
local args = env.ARGS or {}

local C = {
    R="\27[37m", G="\27[32m", Y="\27[33m", C="\27[36m",
    E="\27[31m", D="\27[90m", B="\27[34m", M="\27[35m",
}

-- =============================================
-- STATE
-- =============================================

local g_hDev      = nil
local g_tDisk     = nil
local g_tRdb      = nil
local g_sDev      = nil
local g_tDevInfo  = nil
local g_tPartDisk = {}
local g_tVol      = {}
local g_tCwd      = {}

-- =============================================
-- HELPERS
-- =============================================

local function die(s) print(C.E .. "Error: " .. C.R .. s) end
local function ok(s)  print(C.G .. "  [OK] " .. C.R .. s) end

local function fmtSz(n)
    if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
    if n >= 1024    then return string.format("%.1f KB", n / 1024) end
    return n .. " B"
end

local function yieldFlush()
    syscall("process_yield")
end

local function parseLine(sLine)
    local t = {}
    local cur = ""
    local inQ = false
    for i = 1, #sLine do
        local c = sLine:sub(i, i)
        if c == '"' then inQ = not inQ
        elseif c == ' ' and not inQ then
            if #cur > 0 then t[#t+1] = cur; cur = "" end
        else cur = cur .. c end
    end
    if #cur > 0 then t[#t+1] = cur end
    return t
end

-- =============================================
-- DEVICE MANAGEMENT
-- =============================================

local function closeDevice()
    for idx in pairs(g_tVol) do
        pcall(function() g_tVol[idx]:flush() end)
    end
    g_tVol = {}; g_tPartDisk = {}; g_tCwd = {}
    if g_hDev then fs.close(g_hDev); g_hDev = nil end
    g_tDisk = nil; g_tRdb = nil; g_sDev = nil; g_tDevInfo = nil
end

local function openDevice(sPath)
    closeDevice()
    local h = fs.open(sPath, "r")
    if not h then return nil, "Cannot open " .. sPath end
    local bI, tI = fs.deviceControl(h, "info", {})
    if not bI or not tI then
        fs.close(h); return nil, "Device info failed (blkdev loaded?)"
    end
    g_hDev = h; g_sDev = sPath; g_tDevInfo = tI
    local ss = tI.sectorSize
    g_tDisk = {
        sectorSize  = ss,
        sectorCount = tI.sectorCount,
        readSector = function(n)
            local bOk, d = fs.deviceControl(h, "read_sector", {n + 1})
            return bOk and d or nil
        end,
        writeSector = function(n, d)
            d = B.pad(d or "", ss)
            return fs.deviceControl(h, "write_sector", {n + 1, d:sub(1, ss)})
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

local function getVol(nIdx, tMountOpts)
    tMountOpts = tMountOpts or { cacheSize = 32 }

    if not tMountOpts and g_tVol[nIdx] then return g_tVol[nIdx] end
    local tPD = getPartDisk(nIdx)
    if not tPD then return nil, "No partition " .. nIdx end
    -- Unmount previous if re-mounting with different options
    if g_tVol[nIdx] then
        pcall(function() g_tVol[nIdx]:flush() end)
        g_tVol[nIdx] = nil
    end
    local vol, e = AX.mount(tPD, tMountOpts)
    if not vol then return nil, e end
    g_tVol[nIdx] = vol
    g_tCwd[nIdx] = "/"
    return vol
end

local function resolvePart(s)
    if not g_tRdb then return nil end
    local n = tonumber(s)
    if n and g_tRdb.partitions[n + 1] then return n end
    for i, p in ipairs(g_tRdb.partitions) do
        if p.deviceName == s or p.fsLabel == s then return i - 1 end
    end
    return nil
end

local function resolveAxPath(nIdx, sPath)
    if not sPath or sPath == "" then return g_tCwd[nIdx] or "/" end
    if sPath:sub(1, 1) == "/" then return sPath end
    local sCwd = g_tCwd[nIdx] or "/"
    if sCwd == "/" then return "/" .. sPath end
    return sCwd .. "/" .. sPath
end

local function ensureParents(vol, sPath)
    local tParts = {}
    for seg in sPath:gmatch("[^/]+") do tParts[#tParts+1] = seg end
    if #tParts <= 1 then return end
    local sDir = ""
    for i = 1, #tParts - 1 do
        sDir = sDir .. "/" .. tParts[i]
        if not vol:stat(sDir) then vol:mkdir(sDir) end
    end
end

-- =============================================
-- @RDB::Partition DISPLAY HELPERS
-- =============================================

-- Build a compact flags string for partition display
local function fmtPartFlags(p)
    local tFlags = {}
    local nF = p.flags or 0

    -- Standard Amiga flags
    if bit32.band(nF, RDB.PF_BOOTABLE)  ~= 0 then tFlags[#tFlags+1] = "boot" end
    if bit32.band(nF, RDB.PF_AUTOMOUNT) ~= 0 then tFlags[#tFlags+1] = "auto" end
    if bit32.band(nF, RDB.PF_READONLY)  ~= 0 then tFlags[#tFlags+1] = "ro" end

    -- @RDB::Partition extended flags
    if bit32.band(nF, RDB.PF_HIDDEN_FS) ~= 0 then tFlags[#tFlags+1] = "hidden" end
    if bit32.band(nF, RDB.PF_SYSTEM)    ~= 0 then tFlags[#tFlags+1] = "system" end
    if bit32.band(nF, RDB.PF_ENCRYPTED) ~= 0 then tFlags[#tFlags+1] = "enc" end

    return table.concat(tFlags, ",")
end

-- Build a compact role string from @RDB::Partition extension
local function fmtPartRole(p)
    if not p.ext or not p.ext._valid then return "" end
    local tRoles = {
        [RDB.ROLE_DATA]       = "",
        [RDB.ROLE_EFI_STAGE3] = "EFI-Stage3",
        [RDB.ROLE_RECOVERY]   = "Recovery",
        [RDB.ROLE_SWAP]       = "Swap",
        [RDB.ROLE_AXFS_ROOT]  = "Root",
    }
    return tRoles[p.ext.bootRole] or ""
end

-- Get the visibility mode string
local function fmtVisibility(p)
    if not p.ext or not p.ext._valid then return "normal" end
    local tVis = {
        [RDB.VIS_NORMAL]    = "normal",
        [RDB.VIS_HIDDEN_FS] = "hidden-fs",
        [RDB.VIS_SYSTEM]    = "system",
    }
    return tVis[p.ext.visibility] or "normal"
end

-- Get the encryption type string
local function fmtEncryption(p)
    if not p.ext or not p.ext._valid then return "none" end
    local tEnc = {
        [RDB.ENC_NONE]      = "none",
        [RDB.ENC_XOR_HMAC]  = "HMAC-XOR",
        [RDB.ENC_DATA_CARD] = "DataCard",
    }
    return tEnc[p.ext.encryptType] or "none"
end

-- Get the integrity mode string
local function fmtIntegrity(p)
    if not p.ext or not p.ext._valid then return "" end
    local tInt = {
        [RDB.INTEGRITY_NONE]   = "",
        [RDB.INTEGRITY_CRC32]  = "CRC32",
        [RDB.INTEGRITY_SHA256] = "SHA-256",
    }
    return tInt[p.ext.integrityMode] or ""
end

-- Check if a partition has valid @RDB::Partition extensions
local function hasExtension(p)
    return p.ext and p.ext._valid
end

-- =============================================
-- SCAN — find block devices
-- =============================================

local function cmdScan()
    local tDev = fs.list("/dev")
    if not tDev then die("Cannot list /dev"); return end
    local n = 0
    for _, sName in ipairs(tDev) do
        local sClean = sName:gsub("/$", "")
        if sClean:find("drive", 1, true) then
            local hD = fs.open("/dev/" .. sClean, "r")
            if hD then
                local bI, tI = fs.deviceControl(hD, "info", {})
                fs.close(hD)
                if bI and tI then
                    n = n + 1
                    local nCap = tI.capacity or (tI.sectorCount * tI.sectorSize)
                    print(string.format("  %s%-24s%s %7s  %d×%dB",
                        C.Y, "/dev/" .. sClean, C.R,
                        fmtSz(nCap), tI.sectorCount, tI.sectorSize))
                end
            end
        end
    end
    if n == 0 then
        die("No block devices. Load driver: " .. C.Y .. "insmod blkdev" .. C.R)
    end
end

-- =============================================
-- PARTITION TABLE DISPLAY (with @RDB::Partition)
-- =============================================

local function cmdParts()
    if not g_tRdb then
        print(C.D .. "  No RDB on this device. Use 'init' to create one." .. C.R)
        return
    end
    local ss = g_tDisk.sectorSize

    print(C.C .. "  Disk: " .. C.R .. (g_tRdb.label or "?") ..
          "  " .. fmtSz(g_tRdb.totalSectors * ss) ..
          "  gen=" .. (g_tRdb.generation or 0))

    if #g_tRdb.partitions == 0 then
        print(C.D .. "  No partitions. Use 'addpart <name>' to create one." .. C.R)
        return
    end

    -- Detect if any partition has @RDB::Partition extensions
    local bAnyExt = false
    for _, p in ipairs(g_tRdb.partitions) do
        if hasExtension(p) then bAnyExt = true; break end
    end

    -- Header
    print("")
    print(string.format("  %s%-3s %-8s %-8s %-10s %8s %10s %-16s%s",
        C.D, "#", "DEVICE", "LABEL", "FSTYPE", "START", "SIZE", "FLAGS", C.R))
    print(C.D .. "  " .. string.rep("-", 72) .. C.R)

    for i, p in ipairs(g_tRdb.partitions) do
        local nIdx = i - 1
        local sFlags = fmtPartFlags(p)

        -- Use RDB.getDisplayLabel for the label shown in tools
        local sDisplayLabel = RDB.getDisplayLabel(p)
        -- Color code based on partition type
        local sLabelColor = C.R
        if RDB.isEfiPartition(p) then
            sLabelColor = C.M  -- magenta for EFI/SYSTEM
        elseif RDB.isHiddenFromFS(p) then
            sLabelColor = C.D  -- dim for hidden
        end

        local sDevColor = C.Y
        if RDB.isEncrypted(p) then
            sDevColor = C.E  -- red tint for encrypted
        end

        print(string.format("  %-3d %s%-8s%s %s%-8s%s %-10s %8d %10s %s",
            nIdx,
            sDevColor, p.deviceName or "?", C.R,
            sLabelColor, sDisplayLabel, C.R,
            RDB.fsTypeName(p.fsType),
            p.startSector,
            fmtSz(p.sizeSectors * ss),
            sFlags))

        -- @RDB::Partition extension detail line
        if hasExtension(p) then
            local tDetail = {}
            local sRole = fmtPartRole(p)
            if #sRole > 0 then tDetail[#tDetail+1] = "role=" .. sRole end

            local sVis = fmtVisibility(p)
            if sVis ~= "normal" then tDetail[#tDetail+1] = "vis=" .. sVis end

            local sEnc = fmtEncryption(p)
            if sEnc ~= "none" then tDetail[#tDetail+1] = "enc=" .. sEnc end

            local sInt = fmtIntegrity(p)
            if #sInt > 0 then tDetail[#tDetail+1] = "check=" .. sInt end

            if p.ext.extVersion and p.ext.extVersion > 0 then
                tDetail[#tDetail+1] = "extv=" .. p.ext.extVersion
            end

            if #tDetail > 0 then
                print(C.D .. "      @RDB: " .. table.concat(tDetail, "  ") .. C.R)
            end

            -- Show binding/hash info for EFI partitions
            if RDB.isEfiPartition(p) then
                if p.ext.bindingHash and #p.ext.bindingHash > 0 then
                    local sHex = ""
                    local bHasData = false
                    for j = 1, math.min(#p.ext.bindingHash, 8) do
                        local b = p.ext.bindingHash:byte(j)
                        if b ~= 0 then bHasData = true end
                        sHex = sHex .. string.format("%02x", b)
                    end
                    if bHasData then
                        print(C.D .. "      bind: " .. sHex .. "..." .. C.R)
                    end
                end
                if p.ext.contentCrc and p.ext.contentCrc ~= 0 then
                    print(C.D .. string.format("      crc:  %08X  size: %d bytes",
                        p.ext.contentCrc, p.ext.encContentLen or 0) .. C.R)
                end
            end
        end
    end

    -- Free space
    local nFree = g_tRdb.totalSectors - RDB.nextFree(g_tRdb)
    if nFree > 0 then
        print("")
        print(C.D .. "  Free: " .. nFree .. " sectors (" ..
              fmtSz(nFree * ss) .. ")" .. C.R)
    end

    -- Summary line
    local nEfi = 0
    local nAxfs = 0
    local nHidden = 0
    local nEnc = 0
    for _, p in ipairs(g_tRdb.partitions) do
        if RDB.isEfiPartition(p) then nEfi = nEfi + 1 end
        if p.fsType == RDB.FS_AXFS2 or p.fsType == RDB.FS_AXFS1 then nAxfs = nAxfs + 1 end
        if RDB.isHiddenFromFS(p) then nHidden = nHidden + 1 end
        if RDB.isEncrypted(p) then nEnc = nEnc + 1 end
    end

    if bAnyExt then
        print("")
        local tSum = {}
        tSum[#tSum+1] = #g_tRdb.partitions .. " partition(s)"
        if nEfi > 0 then tSum[#tSum+1] = nEfi .. " EFI" end
        if nAxfs > 0 then tSum[#tSum+1] = nAxfs .. " AXFS" end
        if nHidden > 0 then tSum[#tSum+1] = nHidden .. " hidden" end
        if nEnc > 0 then tSum[#tSum+1] = nEnc .. " encrypted" end
        print(C.D .. "  Summary: " .. table.concat(tSum, ", ") ..
              "  (@RDB::Partition v" ..
              tostring(g_tRdb.partitions[1].ext and g_tRdb.partitions[1].ext.extVersion or "?") ..
              ")" .. C.R)
    end
end

-- =============================================
-- DETAILED PARTITION INFO (new: 'partinfo' command)
-- =============================================

local function cmdPartInfo(sPart)
    if not sPart then die("Usage: partinfo <part>"); return end
    if not g_tRdb then die("No RDB"); return end
    local nIdx = resolvePart(sPart)
    if not nIdx then die("Unknown partition: " .. sPart); return end
    local p = g_tRdb.partitions[nIdx + 1]
    local ss = g_tDisk.sectorSize

    print(C.C .. "  Partition " .. nIdx .. " — Detailed Info" .. C.R)
    print("")
    print("  " .. C.Y .. "Standard Amiga RDB Fields:" .. C.R)
    print("    Device Name:   " .. (p.deviceName or "?"))
    print("    FS Label:      " .. (p.fsLabel or ""))
    print("    Display Label: " .. C.M .. RDB.getDisplayLabel(p) .. C.R)
    print("    FS Type:       " .. RDB.fsTypeName(p.fsType) ..
          string.format(" (0x%08X)", p.fsType))
    print("    Start Sector:  " .. p.startSector)
    print("    Size Sectors:  " .. p.sizeSectors)
    print("    Size:          " .. fmtSz(p.sizeSectors * ss))
    print("    End Sector:    " .. (p.startSector + p.sizeSectors - 1))
    print("    Boot Priority: " .. (p.bootPriority or 0))
    print("    Reserved:      " .. (p.reserved or 0))
    print("    DH Index:      " .. (p.dhIndex or 0))
    print("    Flags:         " .. fmtPartFlags(p) ..
          string.format(" (0x%04X)", p.flags or 0))
    print("")

    -- Standard flag breakdown
    print("  " .. C.Y .. "Flag Bits:" .. C.R)
    local nF = p.flags or 0
    print("    [" .. (bit32.band(nF, RDB.PF_BOOTABLE) ~= 0 and "X" or " ") ..
          "] Bootable       (0x01)")
    print("    [" .. (bit32.band(nF, RDB.PF_AUTOMOUNT) ~= 0 and "X" or " ") ..
          "] Automount      (0x02)")
    print("    [" .. (bit32.band(nF, RDB.PF_READONLY) ~= 0 and "X" or " ") ..
          "] Read-Only      (0x04)")
    print("    [" .. (bit32.band(nF, RDB.PF_HIDDEN_FS) ~= 0 and "X" or " ") ..
          "] Hidden from FS (0x08)")
    print("    [" .. (bit32.band(nF, RDB.PF_SYSTEM) ~= 0 and "X" or " ") ..
          "] System         (0x10)")
    print("    [" .. (bit32.band(nF, RDB.PF_ENCRYPTED) ~= 0 and "X" or " ") ..
          "] Encrypted      (0x20)")
    print("")

    -- @RDB::Partition extension
    if hasExtension(p) then
        print("  " .. C.M .. "@RDB::Partition Extension (AXPX):" .. C.R)
        print("    CRC Valid:     " ..
              (p.ext._valid and (C.G .. "YES" .. C.R) or (C.E .. "NO" .. C.R)))
        print("    Ext Version:   " .. (p.ext.extVersion or "?"))
        print("")

        -- Visibility
        local tVisNames = {
            [RDB.VIS_NORMAL]    = "Normal (visible everywhere)",
            [RDB.VIS_HIDDEN_FS] = "Hidden from FS (visible in parted)",
            [RDB.VIS_SYSTEM]    = "SYSTEM (hidden from FS, 'SYSTEM' label in tools)",
        }
        print("    Visibility:    " .. (tVisNames[p.ext.visibility] or "?"))

        -- Encryption
        local tEncNames = {
            [RDB.ENC_NONE]      = "None (plaintext)",
            [RDB.ENC_XOR_HMAC]  = "HMAC-XOR Keystream (counter mode)",
            [RDB.ENC_DATA_CARD] = "OC Data Card (Tier 2+ AES)",
        }
        print("    Encryption:    " .. (tEncNames[p.ext.encryptType] or "?"))

        -- Boot Role
        local tRoleNames = {
            [RDB.ROLE_DATA]       = "Data (no boot role)",
            [RDB.ROLE_EFI_STAGE3] = "EFI Third-Layer Bootloader",
            [RDB.ROLE_RECOVERY]   = "Recovery Partition",
            [RDB.ROLE_SWAP]       = "Swap",
            [RDB.ROLE_AXFS_ROOT]  = "AXFS Root (main OS)",
        }
        print("    Boot Role:     " .. (tRoleNames[p.ext.bootRole] or "?"))

        -- Integrity
        local tIntNames = {
            [RDB.INTEGRITY_NONE]   = "None",
            [RDB.INTEGRITY_CRC32]  = "CRC32",
            [RDB.INTEGRITY_SHA256] = "SHA-256",
        }
        print("    Integrity:     " .. (tIntNames[p.ext.integrityMode] or "?"))

        -- Hashes
        if p.ext.contentCrc and p.ext.contentCrc ~= 0 then
            print(string.format("    Content CRC:   %08X", p.ext.contentCrc))
        end
        if p.ext.encContentLen and p.ext.encContentLen > 0 then
            print(string.format("    Enc Size:      %d bytes", p.ext.encContentLen))
        end
        print("")

        -- Binding hash
        if p.ext.bindingHash and #p.ext.bindingHash > 0 then
            local bHasData = false
            local sHex = ""
            for j = 1, #p.ext.bindingHash do
                if p.ext.bindingHash:byte(j) ~= 0 then bHasData = true end
                sHex = sHex .. string.format("%02x", p.ext.bindingHash:byte(j))
            end
            if bHasData then
                print("    Binding Hash:  " .. sHex:sub(1, 32) .. "...")
            else
                print("    Binding Hash:  (not set)")
            end
        end

        -- Content hash
        if p.ext.contentHash and #p.ext.contentHash > 0 then
            local bHasData = false
            local sHex = ""
            for j = 1, #p.ext.contentHash do
                if p.ext.contentHash:byte(j) ~= 0 then bHasData = true end
                sHex = sHex .. string.format("%02x", p.ext.contentHash:byte(j))
            end
            if bHasData then
                print("    Content Hash:  " .. sHex:sub(1, 32) .. "...")
            else
                print("    Content Hash:  (not set)")
            end
        end

        -- Extended flags
        if p.ext.extFlags2 and p.ext.extFlags2 ~= 0 then
            print(string.format("    Ext Flags2:    0x%08X", p.ext.extFlags2))
        end
    else
        print("  " .. C.D .. "@RDB::Partition Extension: Not present (legacy partition)" .. C.R)
    end

    -- Is-checks
    print("")
    print("  " .. C.Y .. "Status:" .. C.R)
    print("    Is EFI:        " ..
          (RDB.isEfiPartition(p) and (C.M .. "YES" .. C.R) or "no"))
    print("    Is Hidden:     " ..
          (RDB.isHiddenFromFS(p) and (C.E .. "YES (not visible to AXFS)" .. C.R) or "no"))
    print("    Is Encrypted:  " ..
          (RDB.isEncrypted(p) and (C.E .. "YES (requires SecureBoot key)" .. C.R) or "no"))
end

-- =============================================
-- PARTITION COMMANDS
-- =============================================

local function cmdInit()
    if g_tRdb then
        io.write(C.Y .. "  Device has an RDB. Overwrite? (y/N): " .. C.R)
        local s = io.read(); if not s or s:lower() ~= "y" then return end
    end
    local tNew = {
        label = "AxisDisk", totalSectors = g_tDisk.sectorCount,
        generation = 0, partitions = {},
    }
    RDB.write(g_tDisk, tNew)
    g_tRdb = RDB.read(g_tDisk)
    g_tVol = {}; g_tPartDisk = {}
    ok("RDB initialized")
end

local function cmdAddPart(sName, sSz)
    if not g_tRdb then die("No RDB. Run 'init' first."); return end
    if not sName then die("Usage: addpart <name> [sectors]"); return end
    if #g_tRdb.partitions >= RDB.MAX_PARTS then die("Max partitions reached"); return end
    local nStart = RDB.nextFree(g_tRdb)
    local nFree  = g_tRdb.totalSectors - nStart
    local nSz    = tonumber(sSz) or 0
    if nSz <= 0 then nSz = nFree end
    if nFree <= 0 then die("No free space"); return end
    if nSz > nFree then die("Only " .. nFree .. " sectors free"); return end
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
    ok(string.format("Partition '%s' (#%d): %d sectors (%s)",
        sName, #g_tRdb.partitions - 1, nSz, fmtSz(nSz * g_tDisk.sectorSize)))
end

local function cmdRmPart(sIdx)
    if not g_tRdb then die("No RDB"); return end
    local n = tonumber(sIdx)
    if not n or not g_tRdb.partitions[n + 1] then die("Invalid index"); return end
    local sRm = g_tRdb.partitions[n + 1].deviceName or "?"
    table.remove(g_tRdb.partitions, n + 1)
    RDB.write(g_tDisk, g_tRdb); g_tRdb = RDB.read(g_tDisk)
    g_tVol[n] = nil; g_tPartDisk[n] = nil
    ok("Removed partition " .. n .. " (" .. sRm .. ")")
end

local function cmdFormat(sPart, sLabel)
    if not sPart then die("Usage: format <part> [label]"); return end
    local nIdx = resolvePart(sPart)
    if not nIdx then die("Unknown partition: " .. sPart); return end
    local p = g_tRdb.partitions[nIdx + 1]

    -- Warn about formatting EFI partitions
    if RDB.isEfiPartition(p) then
        print(C.E .. "  WARNING: This is an EFI partition!" .. C.R)
        print(C.E .. "  Formatting will destroy the SecureBoot bootloader." .. C.R)
        io.write(C.E .. "  Are you SURE? (type 'DESTROY'): " .. C.R)
        local s = io.read(); if s ~= "DESTROY" then return end
    end

    local tPD = getPartDisk(nIdx)
    if not tPD then die("Cannot access partition"); return end
    sLabel = sLabel or p.fsLabel or p.deviceName or "AxisFS"

    io.write(C.Y .. "  Format partition " .. nIdx .. " '" .. sLabel ..
             "' — all data lost. Continue? (y/N): " .. C.R)
    local s = io.read(); if not s or s:lower() ~= "y" then return end
    g_tVol[nIdx] = nil
    local bOk, e = AX.format(tPD, sLabel)
    if bOk then
        ok("Formatted '" .. sLabel .. "' (" .. fmtSz(tPD.sectorCount * tPD.sectorSize) .. ")")
    else
        die("Format failed: " .. tostring(e))
    end
end

-- =============================================
-- FILESYSTEM INFO & CHECK
-- =============================================

local function cmdInfo(sPart)
    if not sPart then die("Usage: info <part>"); return end
    local nIdx = resolvePart(sPart)
    if not nIdx then die("Unknown partition"); return end

    -- Check if this is an EFI partition (not AXFS)
    local p = g_tRdb.partitions[nIdx + 1]
    if RDB.isEfiPartition(p) then
        print(C.M .. "  EFI Partition (not an AXFS volume)" .. C.R)
        print("    Use 'partinfo " .. nIdx .. "' for @RDB::Partition details")
        return
    end

    local vol, e = getVol(nIdx)
    if not vol then die(e); return end
    local t = vol:info()
    print(C.C .. "  AXFS Volume: " .. C.R .. t.label)
    print("    Version:     " .. (t.version or "?"))
    print("    Sector size: " .. t.sectorSize)
    print("    Inodes:      " .. t.maxInodes .. " (free: " .. t.freeInodes .. ")")
    print("    Blocks:      " .. t.maxBlocks .. " (free: " .. t.freeBlocks .. ")")
    print("    Used:        " .. fmtSz(t.usedKB * 1024) .. " / " .. fmtSz(t.totalKB * 1024))
    print("    Generation:  " .. (t.generation or 0))
    if t.inlineSupport then
        print("    Inline:      " .. C.G .. "yes (≤52B in inode)" .. C.R)
    end
end

local function cmdCheck(sPart)
    if not sPart then die("Usage: check <part>"); return end
    local nIdx = resolvePart(sPart)
    if not nIdx then die("Unknown partition"); return end

    local p = g_tRdb.partitions[nIdx + 1]
    if RDB.isEfiPartition(p) then
        print(C.M .. "  Cannot fsck an EFI partition." .. C.R)
        return
    end

    local vol, e = getVol(nIdx)
    if not vol then die(e); return end
    local t = vol:info()
    local nIssues = 0
    print(C.C .. "  Checking AXFS volume '" .. t.label .. "'..." .. C.R)
    if vol.su._crcValid == false then
        print(C.E .. "    Superblock CRC INVALID" .. C.R)
        nIssues = nIssues + 1
    else
        print(C.G .. "    Superblock CRC OK" .. C.R)
    end
    local ri = vol:ri(AX.ROOT_INO)
    if not ri or ri.iType ~= AX.DIR then
        print(C.E .. "    Root inode MISSING or corrupted" .. C.R)
        nIssues = nIssues + 1
    else
        print(C.G .. "    Root inode OK (type=DIR, size=" .. ri.size .. ")" .. C.R)
    end
    local nFiles, nDirs, nInline, nBadCrc = 0, 0, 0, 0
    local function walk(sPath, nIno)
        local ents = vol:listDir(sPath)
        if not ents then return end
        for _, ent in ipairs(ents) do
            local sChild = (sPath == "/" and "" or sPath) .. "/" .. ent.name
            if ent.iType == 2 then
                nDirs = nDirs + 1
                walk(sChild, ent.inode)
            elseif ent.iType == 1 then
                nFiles = nFiles + 1
                if ent.inline then nInline = nInline + 1 end
                local ci = vol:ri(ent.inode)
                if ci and ci._crcValid == false then
                    nBadCrc = nBadCrc + 1
                    print(C.E .. "    Bad inode CRC: " .. sChild .. C.R)
                end
            end
        end
    end
    walk("/", AX.ROOT_INO)
    yieldFlush()
    print(string.format("    Files: %d (%d inline), Dirs: %d", nFiles, nInline, nDirs))
    if nBadCrc > 0 then
        print(C.E .. "    BAD INODE CRCs: " .. nBadCrc .. C.R)
        nIssues = nIssues + nBadCrc
    end
    local nUsedBlocks = t.maxBlocks - t.freeBlocks
    local nUsedInodes = t.maxInodes - t.freeInodes
    print(string.format("    Blocks used: %d/%d   Inodes used: %d/%d",
        nUsedBlocks, t.maxBlocks, nUsedInodes, t.maxInodes))
    if nIssues == 0 then
        print(C.G .. "  Filesystem is clean." .. C.R)
    else
        print(C.E .. "  " .. nIssues .. " issue(s) found!" .. C.R)
    end
end

-- =============================================
-- FILE OPERATIONS
-- =============================================

local function cmdLs(sPart, sPath)
    if not sPart then die("Usage: ls <part> [path]"); return end
    local nIdx = resolvePart(sPart)
    if not nIdx then die("Unknown partition"); return end

    local p = g_tRdb.partitions[nIdx + 1]
    if RDB.isEfiPartition(p) then
        print(C.M .. "  Cannot list files on EFI partition (encrypted/raw)" .. C.R)
        return
    end

    local vol, e = getVol(nIdx)
    if not vol then die(e); return end
    local sResolved = resolveAxPath(nIdx, sPath)
    local ents, le = vol:listDir(sResolved)
    if not ents then die(le); return end
    print(C.D .. "  " .. sResolved .. C.R)
    for _, ent in ipairs(ents) do
        local sT   = ({[1]="f",[2]="d",[3]="l"})[ent.iType] or "?"
        local sClr = ent.iType == 2 and C.C or C.R
        local sTag = ent.inline and (C.D .. " [inline]" .. C.R) or ""
        print(string.format("    %s %6d  %s%s%s%s",
            sT, ent.size, sClr, ent.name, C.R, sTag))
    end
    if #ents == 0 then print(C.D .. "    (empty)" .. C.R) end
end

local function cmdCd(sPart, sPath)
    if not sPart or not sPath then die("Usage: cd <part> <path>"); return end
    local nIdx = resolvePart(sPart)
    if not nIdx then die("Unknown partition"); return end
    local vol, e = getVol(nIdx)
    if not vol then die(e); return end
    local sResolved = resolveAxPath(nIdx, sPath)
    if sPath == ".." then
        local sCwd = g_tCwd[nIdx] or "/"
        sResolved = sCwd:match("(.*/)[^/]+/?$") or "/"
        if #sResolved > 1 and sResolved:sub(-1) == "/" then
            sResolved = sResolved:sub(1, -2)
        end
    end
    local st = vol:stat(sResolved)
    if not st or st.iType ~= AX.DIR then
        die("Not a directory: " .. sResolved); return
    end
    g_tCwd[nIdx] = sResolved
    print(C.D .. "  " .. sResolved .. C.R)
end

local function cmdMkdir(sPart, sPath)
    if not sPart or not sPath then die("Usage: mkdir <part> <path>"); return end
    local nIdx = resolvePart(sPart)
    if not nIdx then die("Unknown partition"); return end
    local vol, e = getVol(nIdx)
    if not vol then die(e); return end
    local sR = resolveAxPath(nIdx, sPath)
    local bOk, fe = vol:mkdir(sR)
    if bOk then ok("Created " .. sR) else die(fe) end
end

local function cmdTouch(sPart, sPath)
    if not sPart or not sPath then die("Usage: touch <part> <path>"); return end
    local nIdx = resolvePart(sPart)
    if not nIdx then die("Unknown partition"); return end
    local vol, e = getVol(nIdx)
    if not vol then die(e); return end
    local sR = resolveAxPath(nIdx, sPath)
    if vol:stat(sR) then ok(sR .. " (exists)"); return end
    ensureParents(vol, sR)
    local bOk, fe = vol:writeFile(sR, "")
    if bOk then ok("Created " .. sR) else die(fe) end
end

local function cmdRm(sPart, sPath)
    if not sPart or not sPath then die("Usage: rm <part> <path>"); return end
    local nIdx = resolvePart(sPart)
    if not nIdx then die("Unknown partition"); return end
    local vol, e = getVol(nIdx)
    if not vol then die(e); return end
    local sR = resolveAxPath(nIdx, sPath)
    local bOk = vol:removeFile(sR)
    if not bOk then bOk = vol:rmdir(sR) end
    if bOk then ok("Removed " .. sR) else die("Failed to remove " .. sR) end
end

local function cmdCat(sPart, sPath)
    if not sPart or not sPath then die("Usage: cat <part> <path>"); return end
    local nIdx = resolvePart(sPart)
    if not nIdx then die("Unknown partition"); return end
    local vol, e = getVol(nIdx)
    if not vol then die(e); return end
    local sR = resolveAxPath(nIdx, sPath)
    local data, fe = vol:readFile(sR)
    if data then io.write(data) else die(fe) end
end

local function cmdStat(sPart, sPath)
    if not sPart or not sPath then die("Usage: stat <part> <path>"); return end
    local nIdx = resolvePart(sPart)
    if not nIdx then die("Unknown partition"); return end
    local vol, e = getVol(nIdx)
    if not vol then die(e); return end
    local sR = resolveAxPath(nIdx, sPath)
    local t, fe = vol:stat(sR)
    if not t then die(fe); return end
    local tN = {[0]="free",[1]="file",[2]="dir",[3]="symlink"}
    print(C.C .. "  Inode " .. t.inode .. C.R)
    print("    Type:    " .. (tN[t.iType] or "?"))
    print("    Size:    " .. t.size .. " bytes")
    print("    Mode:    " .. string.format("%03o", t.mode))
    print("    Inline:  " .. tostring(t.isInline or false))
    print("    Extents: " .. (t.nExtents or 0))
    print("    Links:   " .. t.links)
end

-- =============================================
-- FILE TRANSFER (cp)
-- =============================================

local function parseTarget(s)
    local sPart, sPath = s:match("^(%w+):(.+)$")
    if sPart then
        local nIdx = resolvePart(sPart)
        if nIdx then return {part = nIdx, path = sPath} end
    end
    return {localfs = true, path = s}
end

local function cmdCp(sSrc, sDst)
    if not sSrc or not sDst then
        die("Usage: cp <src> <dst>")
        print("    Prefix partition paths with 'N:' e.g. 0:/etc/hostname")
        return
    end
    local tSrc = parseTarget(sSrc)
    local tDst = parseTarget(sDst)

    if tSrc.localfs and tDst.part then
        local vol, e = getVol(tDst.part)
        if not vol then die(e); return end
        local hR = fs.open(tSrc.path, "r")
        if not hR then die("Cannot open " .. tSrc.path); return end
        local tC = {}
        while true do
            local s = fs.read(hR, 4096); if not s then break end
            tC[#tC + 1] = s
        end
        fs.close(hR)
        local sData = table.concat(tC)
        ensureParents(vol, tDst.path)
        local bOk, fe = vol:writeFile(tDst.path, sData)
        if bOk then ok(fmtSz(#sData) .. "  " .. tSrc.path .. " → " .. sDst)
        else die(fe) end

    elseif tSrc.part and tDst.localfs then
        local vol, e = getVol(tSrc.part)
        if not vol then die(e); return end
        local sData, fe = vol:readFile(tSrc.path)
        if not sData then die(fe); return end
        local hW = fs.open(tDst.path, "w")
        if not hW then die("Cannot write " .. tDst.path); return end
        fs.write(hW, sData); fs.close(hW)
        ok(fmtSz(#sData) .. "  " .. sSrc .. " → " .. tDst.path)

    elseif tSrc.part and tDst.part then
        local vS, eS = getVol(tSrc.part)
        local vD, eD = getVol(tDst.part)
        if not vS then die(eS); return end
        if not vD then die(eD); return end
        local sData, fe = vS:readFile(tSrc.path)
        if not sData then die(fe); return end
        ensureParents(vD, tDst.path)
        local bOk, we = vD:writeFile(tDst.path, sData)
        if bOk then ok(fmtSz(#sData) .. "  " .. sSrc .. " → " .. sDst)
        else die(we) end
    else
        die("Both src and dst are local paths. Use 'cp' from the shell.")
    end
end

-- =============================================
-- INSTALL — Copy OS tree with progress bar
-- =============================================

local function cmdInstall(sPart)
    if not sPart then die("Usage: install <part>"); return end
    local nIdx = resolvePart(sPart)
    if not nIdx then die("Unknown partition"); return end

    local p = g_tRdb.partitions[nIdx + 1]
    if RDB.isEfiPartition and RDB.isEfiPartition(p) then
        die("Cannot install OS onto EFI partition.")
        return
    end

    -- Mount with SMALL cache.  Each slot = 512 bytes of sector data.
    -- 24 slots × 512B = 12KB — leaves headroom for file data + IPC.
    local vol, e = getVol(nIdx, { cacheSize = 24 })
    if not vol then die(e); return end

    local tSkip = {
        ["/tmp"]=true, ["/log"]=true, ["/vbl"]=true, ["/dev"]=true,
    }

    -- ── Phase 1: Enumerate ──
    print(C.C .. "  Scanning filesystem..." .. C.R)
    yieldFlush()

    local tEntries = {}
    local function walk(sDir)
        local tList = fs.list(sDir)
        if not tList then return end
        for _, sName in ipairs(tList) do
            local bIsDir = sName:sub(-1) == "/"
            local sClean = bIsDir and sName:sub(1, -2) or sName
            local sSrc   = (sDir == "/" and "" or sDir) .. "/" .. sClean
            sSrc = sSrc:gsub("//", "/")
            if tSkip[sSrc] then goto skip end
            tEntries[#tEntries + 1] = {src = sSrc, isDir = bIsDir}
            if bIsDir then walk(sSrc) end
            if #tEntries % 30 == 0 then yieldFlush() end
            ::skip::
        end
    end
    walk("/")

    local nTotal  = #tEntries
    local nFiles  = 0
    local nDirs   = 0
    local nBytes  = 0
    local nErrors = 0
    local tFailedFiles = {}

    local nDirCount = 0
    for _, ent in ipairs(tEntries) do
        if ent.isDir then nDirCount = nDirCount + 1 end
    end

    print(string.format("  Found %d entries (%d files, %d dirs)",
        nTotal, nTotal - nDirCount, nDirCount))
    io.write(C.Y .. "  Proceed? (y/N): " .. C.R)
    yieldFlush()
    local sConf = io.read()
    if not sConf or sConf:lower() ~= "y" then print("  Aborted."); return end
    print("")

    -- ── Phase 2: Pre-create directories ──
    for _, sDir in ipairs({
        "/bin", "/etc", "/lib", "/drivers", "/system",
        "/usr", "/usr/commands", "/home", "/tmp", "/boot",
        "/system/lib", "/system/lib/dk", "/lib/vi", "/lib/hbm",
        "/lib/xevi", "/sys", "/sys/security", "/sys/drivers",
        "/etc/xevi", "/etc/xevi/plug", "/root", "/home/guest",
        "/boot/sys",
    }) do
        vol:mkdir(sDir)
    end
    -- Flush directory structure to disk AND verify it took.
    -- This is critical: if these writes fail, all subsequent
    -- file writes will get "Not found" errors.
    vol:flush()
    yieldFlush()
    yieldFlush()

    -- ── Phase 3: Copy files ──
    local nBarW = 30
    local nStartTime = computer.uptime()

    -- Purge every 5 FILES.  With 24-slot cache this keeps peak
    -- memory ~12KB cached sectors + ~5KB file data = ~17KB.
    local PURGE_EVERY = 5
    local nFilesSincePurge = 0
    local nProgressUpdate = 0

    for i, ent in ipairs(tEntries) do
        -- ── Progress bar (every 3rd entry to reduce TTY IPC) ──
        nProgressUpdate = nProgressUpdate + 1
        if nProgressUpdate >= 3 or i == nTotal then
            nProgressUpdate = 0
            local nPct  = math.floor(i / nTotal * 100)
            local nFill = math.floor(nPct / 100 * nBarW)
            local sBar  = string.rep("#", nFill) .. string.rep("-", nBarW - nFill)
            local sShort = ent.src:match("([^/]+)$") or ent.src
            if #sShort > 24 then sShort = ".." .. sShort:sub(-22) end
            io.write(string.format("\r  [%s] %3d%% (%d/%d) %-24s",
                sBar, nPct, i, nTotal, sShort))
        end

        if ent.isDir then
            vol:mkdir(ent.src)
            nDirs = nDirs + 1
        else
            -- Read source file from root filesystem
            local hSrc = fs.open(ent.src, "r")
            if hSrc then
                local tC = {}
                while true do
                    local s = fs.read(hSrc, 2048)
                    if not s then break end
                    tC[#tC + 1] = s
                end
                fs.close(hSrc)

                local sData = table.concat(tC)
                tC = nil

                if sData:find("\r\n", 1, true) then
                    sData = sData:gsub("\r\n", "\n")
                end

                local nSz = #sData

                -- Write with retry.  After purgeCache the CLOCK cache
                -- is cold; the first path-resolution may fail if the
                -- IPC round-trip for the sector read fails transiently
                -- (memory pressure, signal queue full, etc).
                -- Retry once after yielding to let GC + IPC drain.
                ensureParents(vol, ent.src)
                local bW, sWE = vol:writeFile(ent.src, sData)

                if not bW then
                    -- Retry: flush dirty state, yield twice for GC,
                    -- then re-attempt the write.
                    vol:flush()
                    yieldFlush()
                    yieldFlush()
                    ensureParents(vol, ent.src)
                    bW, sWE = vol:writeFile(ent.src, sData)
                end

                sData = nil

                if bW then
                    nFiles = nFiles + 1
                    nBytes = nBytes + nSz
                else
                    nErrors = nErrors + 1
                    tFailedFiles[#tFailedFiles + 1] = {
                        path = ent.src, err = tostring(sWE)
                    }
                end
            else
                nErrors = nErrors + 1
                tFailedFiles[#tFailedFiles + 1] = {
                    path = ent.src, err = "Cannot open source file"
                }
            end

            nFilesSincePurge = nFilesSincePurge + 1
        end

        -- ── Memory management ──
        if nFilesSincePurge >= PURGE_EVERY then
            nFilesSincePurge = 0
            -- purgeCache: flush dirty data, then clear all caches.
            vol:purgeCache()
            -- Yield TWICE after purge.  Each yield gives the OC
            -- incremental GC one step to collect the freed sector
            -- data strings (~12KB).  Two steps is enough for OC
            -- to reclaim most of it before we start the next batch.
            yieldFlush()
            yieldFlush()
        elseif i % 4 == 0 then
            -- Light yield every 4th entry for TTY + watchdog
            yieldFlush()
        end
    end

    -- Final cleanup: purge caches to free memory BEFORE printing
    -- the summary (which itself allocates strings).
    vol:purgeCache()
    yieldFlush()

    io.write(string.format("\r  [%s] 100%% (%d/%d) Done!%s\n",
        string.rep("#", nBarW), nTotal, nTotal, string.rep(" ", 20)))

    vol:flush()
    local nElapsed = computer.uptime() - nStartTime

    print("")
    print(C.C .. "  " .. string.rep("=", 46) .. C.R)
    print(C.G .. "  Install complete!" .. C.R)
    print(string.format("    Files:      %d", nFiles))
    print(string.format("    Dirs:       %d", nDirs))
    print(string.format("    Bytes:      %s", fmtSz(nBytes)))
    print(string.format("    Errors:     %s%d%s",
        nErrors > 0 and C.E or C.G, nErrors, C.R))
    print(string.format("    Time:       %.1f seconds", nElapsed))
    if nElapsed > 0 then
        print(string.format("    Speed:      %s/sec", fmtSz(nBytes / nElapsed)))
    end
    print(C.C .. "  " .. string.rep("=", 46) .. C.R)

    -- ── Show ALL failed files at the end ──
    if #tFailedFiles > 0 then
        print("")
        print(C.E .. "  Failed files (" .. #tFailedFiles .. "):" .. C.R)
        for idx, tF in ipairs(tFailedFiles) do
            print(C.E .. "    " .. tF.path .. C.D .. " — " .. tF.err .. C.R)
            if idx >= 30 then
                print(C.D .. "    ... and " .. (#tFailedFiles - 30) .. " more" .. C.R)
                break
            end
        end
        print("")
        print(C.Y .. "  TIP: Re-run 'install " .. tostring(sPart) ..
              "' to retry." .. C.R)
        print(C.Y .. "  (Existing files are overwritten, dirs preserved.)" .. C.R)
    end
    print("")
    print("  Next: flash AXFS EEPROM bootloader:")
    print("    " .. C.Y .. "axfs flash /boot/axfs_boot.lua" .. C.R)

    g_tVol[nIdx] = nil
end

-- =============================================
-- HELP
-- =============================================

local function cmdHelp()
    print(C.C .. "parted" .. C.R .. " — AXFS Drive Manager")
    print("")
    print("  " .. C.Y .. "Device:" .. C.R)
    print("    scan                    List block devices")
    print("    open <device>           Open a different device")
    print("")
    print("  " .. C.Y .. "Partitions:" .. C.R)
    print("    parts                   Show partition table (with @RDB)")
    print("    partinfo <part>         Detailed @RDB::Partition info")
    print("    init                    Create empty RDB")
    print("    addpart <name> [sects]  Add partition (0 = all free)")
    print("    rmpart <index>          Remove partition")
    print("    format <part> [label]   Format as AXFS v2")
    print("")
    print("  " .. C.Y .. "Filesystem:" .. C.R)
    print("    info <part>             Volume info")
    print("    check <part>            Integrity check")
    print("")
    print("  " .. C.Y .. "Files:" .. C.R)
    print("    ls <part> [path]        List directory")
    print("    cd <part> <path>        Change directory")
    print("    cat <part> <path>       Read file")
    print("    stat <part> <path>      Inode details")
    print("    mkdir <part> <path>     Create directory")
    print("    touch <part> <path>     Create empty file")
    print("    rm <part> <path>        Remove file/dir")
    print("")
    print("  " .. C.Y .. "Transfer:" .. C.R)
    print("    cp <src> <dst>          Copy file (prefix AXFS with N:)")
    print("")
    print("  " .. C.Y .. "Install:" .. C.R)
    print("    install <part>          Copy full OS tree (with progress)")
    print("")
    print("  quit / exit               Exit parted")
    print("")
    print("  <part> = index (0,1..) or name (DH0, EFI0, SYSTEM..)")
    print("")
    print("  " .. C.M .. "@RDB::Partition:" .. C.R)
    print("    Extended partition metadata (visibility, encryption,")
    print("    boot role, integrity mode). Shown in 'parts' and 'partinfo'.")
end

-- =============================================
-- COMMAND DISPATCH
-- =============================================

local tDispatch = {
    help     = function(a) cmdHelp() end,
    scan     = function(a) cmdScan() end,
    open     = function(a)
        if not a[1] then die("Usage: open <device>"); return end
        local bOk, e = openDevice(a[1])
        if bOk then
            ok("Opened " .. a[1])
            if g_tRdb then cmdParts()
            else print(C.D .. "  No RDB found. Use 'init' to create one." .. C.R) end
        else die(e) end
    end,
    parts    = function(a) cmdParts() end,
    partinfo = function(a) cmdPartInfo(a[1]) end,
    init     = function(a) cmdInit() end,
    addpart  = function(a) cmdAddPart(a[1], a[2]) end,
    rmpart   = function(a) cmdRmPart(a[1]) end,
    format   = function(a) cmdFormat(a[1], a[2]) end,
    info     = function(a) cmdInfo(a[1]) end,
    check    = function(a) cmdCheck(a[1]) end,
    ls       = function(a) cmdLs(a[1], a[2]) end,
    cd       = function(a) cmdCd(a[1], a[2]) end,
    cat      = function(a) cmdCat(a[1], a[2]) end,
    stat     = function(a) cmdStat(a[1], a[2]) end,
    mkdir    = function(a) cmdMkdir(a[1], a[2]) end,
    touch    = function(a) cmdTouch(a[1], a[2]) end,
    rm       = function(a) cmdRm(a[1], a[2]) end,
    cp       = function(a) cmdCp(a[1], a[2]) end,
    install  = function(a) cmdInstall(a[1]) end,
    quit     = function() return "quit" end,
    exit     = function() return "quit" end,
    q        = function() return "quit" end,
}

-- =============================================
-- MAIN
-- =============================================

-- Non-interactive mode
if #args >= 2 then
    local sDev = args[1]
    local sCmd = args[2]
    local tCmdArgs = {}
    for i = 3, #args do tCmdArgs[#tCmdArgs + 1] = args[i] end

    local bOk, e = openDevice(sDev)
    if not bOk then die(e); return end

    local fHandler = tDispatch[sCmd]
    if fHandler then
        fHandler(tCmdArgs)
    else
        die("Unknown command: " .. sCmd)
    end
    closeDevice()
    return
end

-- Interactive mode
print(C.C .. "╔══════════════════════════════════════╗" .. C.R)
print(C.C .. "║  AxisOS AXFS Drive Manager (parted)  ║" .. C.R)
print(C.C .. "╚══════════════════════════════════════╝" .. C.R)
print("  Type 'help' for commands.")
print("")

if args[1] then
    local bOk, e = openDevice(args[1])
    if bOk then
        ok("Opened " .. args[1])
        if g_tRdb then cmdParts()
        else print(C.D .. "  No RDB. Use 'init' to create one." .. C.R) end
    else
        die(e)
        print("  Use 'scan' to find devices, 'open <dev>' to connect.")
    end
else
    print("  No device specified. Scanning...")
    cmdScan()
    print("")
    print("  Use 'open <device>' to select one.")
end

while true do
    local sPrompt
    if g_sDev then
        local sShort = g_sDev:match("([^/]+)$") or g_sDev
        sPrompt = C.M .. "parted" .. C.D .. ":" .. C.Y .. sShort .. C.R .. "> "
    else
        sPrompt = C.M .. "parted" .. C.R .. "> "
    end
    io.write(sPrompt)
    yieldFlush()

    local sLine = io.read()
    if not sLine then break end
    sLine = sLine:match("^%s*(.-)%s*$") or ""
    if #sLine == 0 then goto next end

    local tParts = parseLine(sLine)
    local sCmd = tParts[1]
    local tCmdArgs = {}
    for i = 2, #tParts do tCmdArgs[#tCmdArgs + 1] = tParts[i] end

    if not sCmd then goto next end

    local tNeedsDev = {
        parts=1, partinfo=1, init=1, addpart=1, rmpart=1, format=1,
        info=1, check=1, ls=1, cd=1, cat=1, stat=1,
        mkdir=1, touch=1, rm=1, cp=1, install=1,
    }
    if tNeedsDev[sCmd] and not g_hDev then
        die("No device open. Use 'open <device>' or 'scan'.")
        goto next
    end

    local fHandler = tDispatch[sCmd]
    if fHandler then
        local vResult = fHandler(tCmdArgs)
        if vResult == "quit" then break end
    else
        die("Unknown command: " .. sCmd .. "  (type 'help')")
    end

    ::next::
end

closeDevice()