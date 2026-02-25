--
-- /sys/security/hvci.lua
-- AxisOS HVCI v2 — Hypervisor-Enforced Code Integrity
--
-- v2 additions:
--   • Capability-based access control (sandbox generation)
--   • Driver load audit trail with timestamps
--   • Runtime periodic integrity rechecks
--   • Memory region protection simulation
--   • Code signing policy tiers (audit/warn/enforce)
--   • Per-driver integrity event counters
--   • Quarantine integration hooks
--

local oHvci = {}

local g_tWhitelist    = {}
local g_bInitialized  = false
local g_nMode         = 0   -- 0=disabled, 1=audit, 2=warn, 3=enforce

-- Audit trail: timestamped record of every driver load decision
local g_tAuditTrail   = {}
local AUDIT_MAX       = 200

-- Per-driver integrity state
local g_tDriverState  = {}  -- [driverName] = {hash, loadTime, lastCheck, violations, caps}

-- Capability registry: maps capability names to component types
local CAPABILITY_MAP = {
    INTERNET_CARD       = {"internet"},
    GPU_ACCESS          = {"gpu"},
    SCREEN_ACCESS       = {"screen"},
    DISK_ACCESS         = {"drive"},
    EEPROM_ACCESS       = {"eeprom"},
    DATA_CARD           = {"data"},
    KEYBOARD_ACCESS     = {"keyboard"},
    RAW_COMPONENT_LIST  = {"__list__"},    -- special: allows raw_component.list()
    RAW_COMPONENT_PROXY = {"__proxy__"},   -- special: allows raw_component.proxy()
    FILESYSTEM_ACCESS   = {"filesystem"},
    REDSTONE_ACCESS     = {"redstone"},
    MODEM_ACCESS        = {"modem"},
    -- HBM mod components
    RBMK_CONTROL        = {"rbmk_console", "rbmk_crane", "rbmk_fuel_rod",
                           "rbmk_control_rod", "rbmk_boiler"},
}

-- Code signing policy tiers
local POLICY_TIERS = {
    [0] = {name="DISABLED",  blockUnsigned=false, blockUnknown=false, blockMismatch=false},
    [1] = {name="AUDIT",     blockUnsigned=false, blockUnknown=false, blockMismatch=false},
    [2] = {name="WARN",      blockUnsigned=false, blockUnknown=false, blockMismatch=true},
    [3] = {name="ENFORCE",   blockUnsigned=true,  blockUnknown=true,  blockMismatch=true},
}

-- =============================================
-- INITIALIZATION
-- =============================================

function oHvci.Initialize(nMode)
    if g_bInitialized then return true end
    g_nMode = nMode or 0
    syscall("kernel_log", "[HVCI] v2 Code Integrity initializing (mode=" .. g_nMode ..
        " / " .. (POLICY_TIERS[g_nMode] or {}).name .. ")...")

    -- Load whitelist from disk
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

    -- Register in registry
    pcall(function()
        syscall("reg_create_key", "@VT\\SYS\\HVCI")
        syscall("reg_set_value", "@VT\\SYS\\HVCI", "Mode", g_nMode, "NUM")
        syscall("reg_set_value", "@VT\\SYS\\HVCI", "PolicyTier",
            (POLICY_TIERS[g_nMode] or {}).name or "?", "STR")
        syscall("reg_set_value", "@VT\\SYS\\HVCI", "WhitelistEntries", nEntries, "NUM")
        syscall("reg_set_value", "@VT\\SYS\\HVCI", "Version", "2.0.0", "STR")
    end)

    g_bInitialized = true
    return true
end

-- =============================================
-- HASH COMPUTATION
-- =============================================

local function computeHash(sCode)
    local oCrypto = nil
    pcall(function()
        oCrypto = require("crypto")
        oCrypto.Init()
    end)
    if oCrypto and oCrypto.SHA256 and oCrypto.Encode64 then
        return oCrypto.Encode64(oCrypto.SHA256(sCode))
    end
    local bOk, oBpack = pcall(require, "bpack")
    if bOk and oBpack and oBpack.crc32 then
        return string.format("CRC32_%08X_%d", oBpack.crc32(sCode), #sCode)
    end
    local nHash = 5381
    for i = 1, math.min(#sCode, 4096) do
        nHash = ((nHash * 33) + sCode:byte(i)) % 0xFFFFFFFF
    end
    return string.format("WEAK_%08X_%d", nHash, #sCode)
end

-- =============================================
-- AUDIT TRAIL
-- =============================================

local function audit(sAction, sDriver, sHash, sReason, tExtra)
    local tEntry = {
        time     = os.clock(),
        action   = sAction,
        driver   = sDriver or "?",
        hash     = sHash and sHash:sub(1, 16) or "?",
        reason   = sReason or "",
        mode     = g_nMode,
    }
    if tExtra then
        for k, v in pairs(tExtra) do tEntry[k] = v end
    end
    g_tAuditTrail[#g_tAuditTrail + 1] = tEntry
    if #g_tAuditTrail > AUDIT_MAX then table.remove(g_tAuditTrail, 1) end

    -- Write to registry
    pcall(function()
        syscall("reg_set_value", "@VT\\SYS\\HVCI", "LastAction", sAction, "STR")
        syscall("reg_set_value", "@VT\\SYS\\HVCI", "LastDriver", sDriver or "?", "STR")
        syscall("reg_set_value", "@VT\\SYS\\HVCI", "TotalAuditEntries", #g_tAuditTrail, "NUM")
    end)

    return tEntry
end

-- =============================================
-- CAPABILITY-BASED SANDBOX GENERATION
-- =============================================

function oHvci.GenerateCapabilitySandbox(tDriverInfo, sDriverPath)
    if not tDriverInfo then return nil, "No driver info" end
    local tCaps = tDriverInfo.capabilities
    if not tCaps or #tCaps == 0 then
        -- No capabilities declared = full access (legacy compatibility)
        -- In ENFORCE mode, this is blocked
        if g_nMode >= 3 then
            audit("CAP_DENIED", tDriverInfo.sDriverName, nil,
                "No capabilities declared (ENFORCE mode requires explicit caps)")
            return nil, "HVCI ENFORCE: Driver must declare capabilities"
        end
        audit("CAP_LEGACY", tDriverInfo.sDriverName, nil,
            "No capabilities — full access (legacy mode)")
        return nil  -- nil = use default sandbox (no restriction)
    end

    -- Build allowed component type set
    local tAllowedTypes = {}
    local bAllowList  = false
    local bAllowProxy = false

    for _, sCap in ipairs(tCaps) do
        local tTypes = CAPABILITY_MAP[sCap]
        if tTypes then
            for _, sType in ipairs(tTypes) do
                if sType == "__list__" then
                    bAllowList = true
                elseif sType == "__proxy__" then
                    bAllowProxy = true
                else
                    tAllowedTypes[sType] = true
                end
            end
        else
            syscall("kernel_log", "[HVCI] Unknown capability: " .. tostring(sCap) ..
                " in driver " .. (tDriverInfo.sDriverName or "?"))
        end
    end

    -- Generate restricted component access functions
    local tRestrictions = {
        tAllowedTypes = tAllowedTypes,
        bAllowList    = bAllowList,
        bAllowProxy   = bAllowProxy,
        tCapabilities = tCaps,
    }

    audit("CAP_SANDBOXED", tDriverInfo.sDriverName, nil,
        "Capabilities: " .. table.concat(tCaps, ", "),
        {caps = tCaps})

    syscall("kernel_log", string.format(
        "[HVCI] Driver '%s' sandboxed with %d capabilities: %s",
        tDriverInfo.sDriverName, #tCaps, table.concat(tCaps, ", ")))

    return tRestrictions
end

-- Check if a component access is allowed by capabilities
function oHvci.CheckCapability(sDriverName, sComponentType, sOperation)
    local tState = g_tDriverState[sDriverName]
    if not tState or not tState.restrictions then return true end

    local tR = tState.restrictions
    if sOperation == "list" and not tR.bAllowList then
        audit("CAP_VIOLATION", sDriverName, nil,
            "raw_component.list() denied — missing RAW_COMPONENT_LIST capability")
        return false
    end
    if sOperation == "proxy" and not tR.bAllowProxy then
        audit("CAP_VIOLATION", sDriverName, nil,
            "raw_component.proxy() denied — missing RAW_COMPONENT_PROXY capability")
        return false
    end
    if sComponentType and not tR.tAllowedTypes[sComponentType] then
        audit("CAP_VIOLATION", sDriverName, nil,
            "Access to '" .. sComponentType .. "' denied — not in declared capabilities")
        return false
    end
    return true
end

-- =============================================
-- DRIVER VALIDATION (MAIN ENTRY POINT)
-- =============================================

function oHvci.ValidateDriver(sDriverCode, sDriverPath, tDriverInfo)
    if not g_bInitialized then oHvci.Initialize() end
    if g_nMode == 0 then return 0 end

    local sHash = computeHash(sDriverCode)
    local sDriverName = (tDriverInfo and tDriverInfo.sDriverName) or sDriverPath or "?"
    local tPolicy = POLICY_TIERS[g_nMode] or POLICY_TIERS[0]

    -- Check quarantine status
    local bQuarantined = false
    pcall(function()
        local v = syscall("reg_get_value",
            "@VT\\DRV\\" .. sDriverName, "Quarantined")
        bQuarantined = (v == true or v == "true")
    end)
    if bQuarantined then
        audit("QUARANTINE_BLOCKED", sDriverName, sHash,
            "Driver is quarantined — refusing load")
        return 422  -- STATUS_QUARANTINE_ENFORCED
    end

    -- Check whitelist
    local tEntry = g_tWhitelist[sHash]
    if tEntry then
        audit("APPROVED", sDriverName, sHash, "Whitelist match")
        oHvci._registerDriver(sDriverName, sHash, tDriverInfo)
        return 0
    end

    -- Not in whitelist
    if tPolicy.blockUnknown then
        audit("BLOCKED", sDriverName, sHash,
            "Not in whitelist (ENFORCE mode)")
        return 540  -- STATUS_HVCI_BLOCKED
    end

    if g_nMode >= 2 then
        audit("WARN_UNKNOWN", sDriverName, sHash,
            "Not in whitelist (WARN mode — allowing)")
        syscall("kernel_log", string.format(
            "[HVCI] WARN: %s NOT in whitelist (hash=%s...)",
            sDriverPath, sHash:sub(1, 16)))
    else
        audit("AUDIT_UNKNOWN", sDriverName, sHash,
            "Not in whitelist (AUDIT mode)")
    end

    oHvci._registerDriver(sDriverName, sHash, tDriverInfo)
    return 0
end

function oHvci._registerDriver(sName, sHash, tDriverInfo)
    local tCaps = nil
    if tDriverInfo and tDriverInfo.capabilities then
        local tR = oHvci.GenerateCapabilitySandbox(tDriverInfo)
        tCaps = tR
    end

    g_tDriverState[sName] = {
        hash         = sHash,
        loadTime     = os.clock(),
        lastCheck    = os.clock(),
        violations   = 0,
        faultCount   = 0,
        caps         = tDriverInfo and tDriverInfo.capabilities or nil,
        restrictions = tCaps,
        path         = tDriverInfo and tDriverInfo.path or nil,
    }
end

-- =============================================
-- RUNTIME INTEGRITY RECHECK
-- =============================================

function oHvci.RuntimeRecheck(fReadFile)
    if g_nMode == 0 then return {} end
    local tViolations = {}

    for sHash, tEntry in pairs(g_tWhitelist) do
        if tEntry.path then
            local sCode = fReadFile(tEntry.path)
            if sCode then
                local sCurHash = computeHash(sCode)
                if sCurHash ~= sHash then
                    tViolations[#tViolations + 1] = {
                        path     = tEntry.path,
                        expected = sHash:sub(1, 16),
                        actual   = sCurHash:sub(1, 16),
                    }
                    audit("INTEGRITY_FAIL", tEntry.path, sCurHash,
                        "Runtime hash mismatch (expected " .. sHash:sub(1,16) .. ")")
                end
            end
        end
    end

    -- Also check registered drivers
    for sName, tState in pairs(g_tDriverState) do
        if tState.path then
            local sCode = fReadFile(tState.path)
            if sCode then
                local sCurHash = computeHash(sCode)
                if sCurHash ~= tState.hash then
                    tState.violations = tState.violations + 1
                    tViolations[#tViolations + 1] = {
                        path     = tState.path,
                        driver   = sName,
                        expected = tState.hash:sub(1, 16),
                        actual   = sCurHash:sub(1, 16),
                    }
                    audit("RUNTIME_TAMPER", sName, sCurHash,
                        "Driver code changed since load!")
                end
                tState.lastCheck = os.clock()
            end
        end
    end

    return tViolations
end

-- =============================================
-- DRIVER FAULT TRACKING (for quarantine system)
-- =============================================

function oHvci.RecordDriverFault(sDriverName, sError)
    local tState = g_tDriverState[sDriverName]
    if not tState then
        tState = {hash="?", loadTime=os.clock(), lastCheck=os.clock(),
                  violations=0, faultCount=0, faultWindow={}}
        g_tDriverState[sDriverName] = tState
    end

    local nNow = os.clock()
    tState.faultWindow = tState.faultWindow or {}

    -- Add fault timestamp
    tState.faultWindow[#tState.faultWindow + 1] = nNow

    -- Prune faults older than 60 seconds
    local tRecent = {}
    for _, nTime in ipairs(tState.faultWindow) do
        if nNow - nTime <= 60 then
            tRecent[#tRecent + 1] = nTime
        end
    end
    tState.faultWindow = tRecent
    tState.faultCount = #tRecent

    audit("DRIVER_FAULT", sDriverName, tState.hash,
        "Error: " .. tostring(sError):sub(1, 80) ..
        " (faults in window: " .. #tRecent .. "/3)")

    -- Return true if quarantine threshold reached
    return #tRecent >= 3
end

function oHvci.QuarantineDriver(sDriverName)
    audit("QUARANTINED", sDriverName, nil,
        "Driver quarantined after 3 faults in 60s")

    -- Mark in registry
    pcall(function()
        local sPath = "@VT\\DRV\\" .. sDriverName
        syscall("reg_create_key", sPath)
        syscall("reg_set_value", sPath, "Quarantined", "true", "STR")
        syscall("reg_set_value", sPath, "QuarantineTime", tostring(os.clock()), "STR")
        syscall("reg_set_value", sPath, "QuarantineReason",
            "3 faults within 60 seconds", "STR")
    end)

    syscall("kernel_log", string.format(
        "[HVCI] ╔══ DRIVER QUARANTINED ══╗"))
    syscall("kernel_log", string.format(
        "[HVCI] ║  %s  ║", sDriverName))
    syscall("kernel_log", string.format(
        "[HVCI] ║  3 faults in 60s       ║"))
    syscall("kernel_log", string.format(
        "[HVCI] ║  Clear via BIOS Setup  ║"))
    syscall("kernel_log", string.format(
        "[HVCI] ╚════════════════════════╝"))

    return true
end

function oHvci.IsQuarantined(sDriverName)
    local bQ = false
    pcall(function()
        local v = syscall("reg_get_value",
            "@VT\\DRV\\" .. sDriverName, "Quarantined")
        bQ = (v == true or v == "true")
    end)
    return bQ
end

function oHvci.ClearQuarantine(sDriverName)
    pcall(function()
        syscall("reg_set_value",
            "@VT\\DRV\\" .. sDriverName, "Quarantined", "false", "STR")
        syscall("reg_delete_value",
            "@VT\\DRV\\" .. sDriverName, "QuarantineTime")
        syscall("reg_delete_value",
            "@VT\\DRV\\" .. sDriverName, "QuarantineReason")
    end)
    local tState = g_tDriverState[sDriverName]
    if tState then
        tState.faultWindow = {}
        tState.faultCount = 0
    end
    audit("QUARANTINE_CLEARED", sDriverName, nil, "Cleared by administrator")
    return true
end

-- =============================================
-- QUERY / STATS
-- =============================================

function oHvci.ComputeHash(sCode) return computeHash(sCode) end
function oHvci.GetWhitelist() return g_tWhitelist end
function oHvci.GetMode() return g_nMode end
function oHvci.SetMode(n) g_nMode = n end
function oHvci.GetAuditTrail() return g_tAuditTrail end
function oHvci.GetDriverState() return g_tDriverState end

function oHvci.GetStats()
    local nDrivers = 0
    local nViolations = 0
    local nQuarantined = 0
    for sName, tS in pairs(g_tDriverState) do
        nDrivers = nDrivers + 1
        nViolations = nViolations + (tS.violations or 0)
        if oHvci.IsQuarantined(sName) then nQuarantined = nQuarantined + 1 end
    end
    local nWL = 0
    for _ in pairs(g_tWhitelist) do nWL = nWL + 1 end
    return {
        nMode            = g_nMode,
        sPolicyTier      = (POLICY_TIERS[g_nMode] or {}).name or "?",
        nWhitelistSize   = nWL,
        nTrackedDrivers  = nDrivers,
        nTotalViolations = nViolations,
        nQuarantined     = nQuarantined,
        nAuditEntries    = #g_tAuditTrail,
    }
end

function oHvci.GenerateWhitelist(tDriverPaths)
    local tNew = {}
    for _, sPath in ipairs(tDriverPaths) do
        local sCode = syscall("vfs_read_file", sPath)
        if sCode then
            local sH = computeHash(sCode)
            tNew[sH] = {path = sPath, size = #sCode}
        end
    end
    return tNew
end

return oHvci