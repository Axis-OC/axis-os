--
-- /sys/security/hvci.lua
-- AxisOS HVCI — Updated for AXFS v2 filesystem
--
-- Changes from previous version:
--   - computeHash works with both managed FS and AXFS proxy
--   - RuntimeRecheck supports AXFS volumes
--   - Whitelist entries include filesystem type for audit
--

local oHvci = {}

local g_tWhitelist   = {}
local g_bInitialized = false
local g_nMode        = 0

function oHvci.Initialize(nMode)
    if g_bInitialized then return true end
    g_nMode = nMode or 0
    syscall("kernel_log", "[HVCI] Code Integrity initializing (mode=" .. g_nMode .. ")...")

    local sCode = syscall("vfs_read_file", "/etc/driver_whitelist.lua")
    if sCode and #sCode > 0 then
        local f = load(sCode, "whitelist", "t", {})
        if f then
            local bOk, tResult = pcall(f)
            if bOk and type(tResult) == "table" then
                g_tWhitelist = tResult
            end
        end
    end

    local nEntries = 0
    for _ in pairs(g_tWhitelist) do nEntries = nEntries + 1 end
    syscall("kernel_log", "[HVCI] Whitelist: " .. nEntries .. " approved driver(s)")
    g_bInitialized = true
    return true
end

-- Hash computation — works with both managed FS and AXFS
-- Uses SHA-256 via data card if available, else weak fallback
local function computeHash(sCode)
    local oCrypto = nil
    pcall(function()
        oCrypto = require("crypto")
        oCrypto.Init()
    end)

    if oCrypto and oCrypto.SHA256 and oCrypto.Encode64 then
        local sRaw = oCrypto.SHA256(sCode)
        return oCrypto.Encode64(sRaw)
    end

    -- Fallback: CRC32 from bpack (AXFS already loaded it)
    local bOk, oBpack = pcall(require, "bpack")
    if bOk and oBpack and oBpack.crc32 then
        local nCrc = oBpack.crc32(sCode)
        return string.format("CRC32_%08X_%d", nCrc, #sCode)
    end

    -- Last resort: weak string hash
    local nHash = 5381
    for i = 1, math.min(#sCode, 4096) do
        nHash = ((nHash * 33) + sCode:byte(i)) % 0xFFFFFFFF
    end
    return string.format("WEAK_%08X_%d", nHash, #sCode)
end

function oHvci.ValidateDriver(sDriverCode, sDriverPath)
    if not g_bInitialized then oHvci.Initialize() end
    if g_nMode == 0 then return 0 end

    local sHash = computeHash(sDriverCode)
    local tEntry = g_tWhitelist[sHash]

    if tEntry then
        syscall("kernel_log", string.format(
            "[HVCI] APPROVED: %s (hash=%s...)",
            sDriverPath, sHash:sub(1, 12)))
        return 0
    end

    if g_nMode == 1 then
        syscall("kernel_log", string.format(
            "[HVCI] AUDIT: %s NOT in whitelist (hash=%s...)",
            sDriverPath, sHash:sub(1, 16)))
        return 0
    end

    syscall("kernel_log", string.format(
        "[HVCI] BLOCKED: %s — hash %s... not in whitelist",
        sDriverPath, sHash:sub(1, 16)))
    return 403
end

-- Runtime recheck — reads files through whatever FS is active
-- (managed or AXFS proxy — both respond to the same primitive_load)
function oHvci.RuntimeRecheck(fReadFile)
    if g_nMode == 0 then return {} end
    local tViolations = {}

    for sHash, tEntry in pairs(g_tWhitelist) do
        if tEntry.path then
            local sCode = fReadFile(tEntry.path)
            if sCode then
                local sCurHash = computeHash(sCode)
                if sCurHash ~= sHash then
                    tViolations[#tViolations+1] = {
                        path = tEntry.path,
                        expected = sHash:sub(1, 16),
                        actual = sCurHash:sub(1, 16),
                    }
                end
            end
        end
    end
    return tViolations
end

function oHvci.ComputeHash(sCode) return computeHash(sCode) end
function oHvci.GetWhitelist() return g_tWhitelist end
function oHvci.GetMode() return g_nMode end
function oHvci.SetMode(n) g_nMode = n end

function oHvci.GenerateWhitelist(tDriverPaths)
    local tNew = {}
    for _, sPath in ipairs(tDriverPaths) do
        local sCode = syscall("vfs_read_file", sPath)
        if sCode then
            local sH = computeHash(sCode)
            tNew[sH] = { path = sPath, size = #sCode }
        end
    end
    return tNew
end

return oHvci