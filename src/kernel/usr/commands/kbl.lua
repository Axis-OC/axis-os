--
-- /usr/commands/kbl.lua
-- KBL (Kernel Bootloader) Management Utility
--
-- Usage:
--   kbl status                   Show KBL partition status
--   kbl install [device]         Install/update KBL shell code
--   kbl set-flag <flag>          Set config flag (force, fallback, locked, verbose)
--   kbl clear-flag <flag>        Clear config flag
--   kbl force                    Set force-enter (boot into KBL next reboot)
--   kbl getvar <name|all>        Read KBL variable
--   kbl setvar <key>=<value>     Set inline variable
--   kbl clear-vars               Clear all inline variables
--   kbl info                     Detailed partition info
--

local fs   = require("filesystem")
local B    = require("bpack")
local RDB  = require("rdb")
local KBL  = require("kbl")
local args = env.ARGS or {}

local sSubcmd = args[1]

-- =============================================
-- HELPERS
-- =============================================

local function die(s) io.write("\27[31m" .. s .. "\27[37m\n"); return end

local function fmtSz(n)
    if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
    if n >= 1024 then return string.format("%.1f KB", n / 1024) end
    return n .. " B"
end

local function fmtFlags(n)
    local t = {}
    if bit32.band(n, KBL.CFG_FORCE_ENTER) ~= 0 then t[#t+1] = "FORCE" end
    if bit32.band(n, KBL.CFG_FALLBACK)    ~= 0 then t[#t+1] = "FALLBACK" end
    if bit32.band(n, KBL.CFG_LOCKED)      ~= 0 then t[#t+1] = "LOCKED" end
    if bit32.band(n, KBL.CFG_VERBOSE)     ~= 0 then t[#t+1] = "VERBOSE" end
    if bit32.band(n, KBL.CFG_AUTO_CLEAR)  ~= 0 then t[#t+1] = "AUTO_CLEAR" end
    if #t == 0 then return "none" end
    return table.concat(t, " | ")
end

local FLAG_NAMES = {
    force      = KBL.CFG_FORCE_ENTER,
    fallback   = KBL.CFG_FALLBACK,
    locked     = KBL.CFG_LOCKED,
    verbose    = KBL.CFG_VERBOSE,
    auto_clear = KBL.CFG_AUTO_CLEAR,
    autoclear  = KBL.CFG_AUTO_CLEAR,
}

-- =============================================
-- FIND KBL PARTITION ON A DRIVE
-- Returns tDisk, nKblOff, nKblSz, tRdb or nil
-- =============================================

local function findKbl(sDevPath)
    local tDrives = {}

    if sDevPath then
        tDrives[1] = sDevPath
    else
        -- Scan /dev for drive devices
        local tDevList = fs.list("/dev")
        if tDevList then
            for _, sName in ipairs(tDevList) do
                local sClean = sName:gsub("/$", "")
                if sClean:find("drive", 1, true) then
                    tDrives[#tDrives + 1] = "/dev/" .. sClean
                end
            end
        end
    end

    for _, sDev in ipairs(tDrives) do
        local hDev = fs.open(sDev, "r")
        if hDev then
            local bI, tI = fs.deviceControl(hDev, "info", {})
            if bI and tI then
                local ss = tI.sectorSize
                local function rs(n)
                    local b, d = fs.deviceControl(hDev, "read_sector", {n + 1})
                    return b and d or nil
                end
                local function ws(n, d)
                    d = B.pad(d or "", ss)
                    return fs.deviceControl(hDev, "write_sector", {n + 1, d:sub(1, ss)})
                end

                local sH = rs(0)
                if sH and sH:sub(1, 4) == "RDSK" then
                    local tDisk = {
                        sectorSize = ss,
                        sectorCount = tI.sectorCount,
                        readSector = rs,
                        writeSector = ws,
                        _hDev = hDev,
                        _sPath = sDev,
                    }
                    local tRdb = RDB.read(tDisk)
                    if tRdb then
                        for i, p in ipairs(tRdb.partitions) do
                            if p.fsType == RDB.FS_AXKBL or p.fsType == 0x41584B42 then
                                local tHdr = KBL.ReadHeader(tDisk, p.startSector)
                                return tDisk, p.startSector, p.sizeSectors, tRdb, tHdr, hDev
                            end
                        end
                    end
                end
            end
            fs.close(hDev)
        end
    end
    return nil
end

-- =============================================
-- LOAD KBL SHELL SOURCE FROM FILESYSTEM
-- Looks for the shell source file on the running OS filesystem.
-- =============================================

local KBL_SHELL_PATHS = {
    "/boot/kbl_shell.lua",
    "/lib/kbl_shell.lua",
    "/system/kbl_shell.lua",
    "/boot/sys/kbl_shell.lua",
}

local function loadShellSource()
    for _, sPath in ipairs(KBL_SHELL_PATHS) do
        local h = fs.open(sPath, "r")
        if h then
            local tC = {}
            while true do
                local s = fs.read(h, 4096)
                if not s then break end
                tC[#tC + 1] = s
            end
            fs.close(h)
            local sCode = table.concat(tC)
            if #sCode > 0 then
                return sCode, sPath
            end
        end
    end
    return nil, nil
end

-- =============================================
-- USAGE
-- =============================================

local function showUsage()
    print("kbl — Kernel Bootloader Management")
    print("")
    print("Usage:")
    print("  kbl status              Show KBL partition status")
    print("  kbl install [/dev/...]  Install/update shell code onto KBL partition")
    print("  kbl force               Set force-enter flag (enter KBL on next boot)")
    print("  kbl set-flag <name>     Set config flag (force/fallback/locked/verbose/auto_clear)")
    print("  kbl clear-flag <name>   Clear config flag")
    print("  kbl getvar <name|all>   Read inline variable")
    print("  kbl setvar <k>=<v>      Set inline variable")
    print("  kbl clear-vars          Clear all inline variables")
    print("  kbl info                Detailed partition + header info")
    print("")
    print("Shell source searched at:")
    for _, s in ipairs(KBL_SHELL_PATHS) do print("  " .. s) end
end

-- =============================================
-- SUBCOMMANDS
-- =============================================

if not sSubcmd or sSubcmd == "help" or sSubcmd == "--help" then
    showUsage()
    return
end

-- ── STATUS ──

if sSubcmd == "status" then
    local tDisk, nOff, nSz, tRdb, tHdr, hDev = findKbl(args[2])
    if not tDisk then
        die("No KBL partition found. Create one with xparted wizard.")
        return
    end

    print("KBL Partition Status")
    print("────────────────────────────────")

    if tHdr then
        print(string.format("  Device:        %s", tDisk._sPath or "?"))
        print(string.format("  Offset:        sector %d", nOff))
        print(string.format("  Size:          %d sectors (%s)", nSz, fmtSz(nSz * tDisk.sectorSize)))
        print(string.format("  Version:       %d", tHdr.nVersion or 0))
        print(string.format("  Label:         %s", tHdr.sLabel or "?"))
        print(string.format("  Config:        0x%02X (%s)", tHdr.nConfig or 0, fmtFlags(tHdr.nConfig or 0)))
        print(string.format("  Code:          %d bytes (%d sectors)", tHdr.nCodeSize or 0, tHdr.nCodeCount or 0))
        print(string.format("  Code CRC:      0x%08X", tHdr.nCodeCrc or 0))
        print(string.format("  Boot attempts: %d", tHdr.nBootAttempts or 0))
        print(string.format("  Kernel fails:  %d", tHdr.nKernelFails or 0))
        print(string.format("  CRC OK:        %s", tHdr.bCrcOk and "yes" or "NO"))

        if tHdr.nCodeSize == 0 then
            print("")
            print("\27[33m  Shell code NOT installed. Run: kbl install\27[37m")
        else
            print(string.format("  Shell ready:   \27[32mYES\27[37m"))
        end
    else
        print("  KBL partition found but header is invalid.")
        print("  Run: kbl install  (will reinitialize)")
    end

    if hDev then fs.close(hDev) end
    return
end

-- ── INSTALL ──

if sSubcmd == "install" then
    -- Step 1: Find KBL partition
    local tDisk, nOff, nSz, tRdb, tHdr, hDev = findKbl(args[2])
    if not tDisk then
        die("No KBL partition found.")
        print("Create one with: xparted → Wizard → Enable KBL partition")
        return
    end

    -- Step 2: Check if locked
    if tHdr and bit32.band(tHdr.nConfig or 0, KBL.CFG_LOCKED) ~= 0 then
        die("KBL partition is LOCKED. Clear with: kbl clear-flag locked")
        if hDev then fs.close(hDev) end
        return
    end

    -- Step 3: Load shell source
    local sShellCode, sSourcePath = loadShellSource()
    if not sShellCode then
        die("KBL shell source not found.")
        print("Expected at one of:")
        for _, s in ipairs(KBL_SHELL_PATHS) do print("  " .. s) end
        print("")
        print("Copy the kbl_shell.lua file to one of these paths and retry.")
        if hDev then fs.close(hDev) end
        return
    end

    print(string.format("Shell source: %s (%d bytes)", sSourcePath, #sShellCode))

    -- Step 4: Check size
    local ss = tDisk.sectorSize
    local nCodeSectors = math.ceil(#sShellCode / ss)
    local nMaxCodeSectors = nSz - 1  -- sector 0 = header
    if nCodeSectors > nMaxCodeSectors then
        die(string.format("Shell too large: %d sectors needed, %d available.",
            nCodeSectors, nMaxCodeSectors))
        if hDev then fs.close(hDev) end
        return
    end

    -- Step 5: Preserve existing config and counters
    local nOldConfig   = (tHdr and tHdr.nConfig) or (KBL.CFG_FALLBACK + KBL.CFG_AUTO_CLEAR)
    local nOldAttempts = (tHdr and tHdr.nBootAttempts) or 0
    local nOldEnter    = (tHdr and tHdr.nLastEnter) or 0
    local nOldFails    = (tHdr and tHdr.nKernelFails) or 0
    local sOldVars     = (tHdr and tHdr.sInlineVars) or ""

    -- Step 6: Compute CRC
    local nCrc = B.crc32(sShellCode)

    -- Step 7: Write code sectors
    print(string.format("Writing %d code sector(s) at offset %d...", nCodeSectors, nOff + 1))
    for i = 0, nCodeSectors - 1 do
        local sChunk = sShellCode:sub(i * ss + 1, (i + 1) * ss)
        tDisk.writeSector(nOff + 1 + i, B.pad(sChunk, ss))
    end

    -- Step 8: Write header
    local nVarStart = 1 + nCodeSectors
    local nVarCount = math.max(0, nSz - nVarStart)

    local tNewHdr = {
        nVersion      = KBL.VERSION,
        nConfig       = nOldConfig,
        nCodeSize     = #sShellCode,
        nCodeCrc      = nCrc,
        nCodeStart    = 1,
        nCodeCount    = nCodeSectors,
        nVarStart     = nVarStart,
        nVarCount     = nVarCount,
        sLabel        = "KBL",
        nBootAttempts = nOldAttempts,
        nLastEnter    = nOldEnter,
        nKernelFails  = nOldFails,
        sInlineVars   = sOldVars,
    }

    KBL.WriteHeader(tDisk, nOff, tNewHdr)

    -- Step 9: Verify
    local tVerify = KBL.ReadHeader(tDisk, nOff)
    if tVerify and tVerify.bCrcOk and tVerify.nCodeSize == #sShellCode then
        print(string.format("\27[32mInstalled successfully.\27[37m"))
        print(string.format("  Code: %d bytes, CRC: 0x%08X", #sShellCode, nCrc))
        print(string.format("  Code sectors: %d  Var sectors: %d", nCodeSectors, nVarCount))
        print(string.format("  Config: 0x%02X (%s)", nOldConfig, fmtFlags(nOldConfig)))
    else
        print("\27[31mVerification FAILED. Header may be corrupt.\27[37m")
    end

    if hDev then fs.close(hDev) end
    return
end

-- ── FORCE ──

if sSubcmd == "force" then
    local tDisk, nOff, nSz, _, tHdr, hDev = findKbl(args[2])
    if not tDisk then die("No KBL partition found."); return end
    if not tHdr or tHdr.nCodeSize == 0 then
        die("KBL shell not installed. Run: kbl install")
        if hDev then fs.close(hDev) end; return
    end
    KBL.SetFlag(tDisk, nOff, KBL.CFG_FORCE_ENTER)
    print("\27[33mForce-enter flag SET.\27[37m")
    print("KBL shell will activate on next reboot.")
    print("Run: reboot")
    if hDev then fs.close(hDev) end
    return
end

-- ── SET-FLAG / CLEAR-FLAG ──

if sSubcmd == "set-flag" or sSubcmd == "clear-flag" then
    local sFlagName = args[2]
    if not sFlagName then die("Usage: kbl " .. sSubcmd .. " <flag-name>"); return end
    local nFlag = FLAG_NAMES[sFlagName:lower()] or tonumber(sFlagName)
    if not nFlag then
        die("Unknown flag: " .. sFlagName)
        print("Known: force, fallback, locked, verbose, auto_clear")
        return
    end
    local tDisk, nOff, _, _, tHdr, hDev = findKbl(args[3])
    if not tDisk then die("No KBL partition."); return end
    if sSubcmd == "set-flag" then
        KBL.SetFlag(tDisk, nOff, nFlag)
        print(string.format("Flag 0x%02X (%s) SET.", nFlag, sFlagName))
    else
        KBL.ClearFlag(tDisk, nOff, nFlag)
        print(string.format("Flag 0x%02X (%s) CLEARED.", nFlag, sFlagName))
    end
    if hDev then fs.close(hDev) end
    return
end

-- ── GETVAR ──

if sSubcmd == "getvar" then
    local sKey = args[2]
    if not sKey then die("Usage: kbl getvar <name|all>"); return end
    local tDisk, nOff, _, _, tHdr, hDev = findKbl(args[3])
    if not tDisk or not tHdr then die("No KBL partition."); return end

    local tVars = KBL.UnpackVars(tHdr.sInlineVars)

    if sKey == "all" then
        print("KBL Inline Variables:")
        local nCount = 0
        for k, v in pairs(tVars) do
            print(string.format("  %-20s = %s", k, v))
            nCount = nCount + 1
        end
        if nCount == 0 then print("  (none)") end
    else
        local v = tVars[sKey]
        if v then
            print(string.format("%s: %s", sKey, v))
        else
            print(string.format("%s: (not set)", sKey))
        end
    end
    if hDev then fs.close(hDev) end
    return
end

-- ── SETVAR ──

if sSubcmd == "setvar" then
    local sExpr = args[2]
    if not sExpr or not sExpr:find("=") then
        die("Usage: kbl setvar key=value"); return
    end
    local sKey, sVal = sExpr:match("^([^=]+)=(.*)")
    if not sKey then die("Invalid key=value"); return end

    local tDisk, nOff, _, _, tHdr, hDev = findKbl(args[3])
    if not tDisk then die("No KBL partition."); return end
    if tHdr and bit32.band(tHdr.nConfig or 0, KBL.CFG_LOCKED) ~= 0 then
        die("KBL is LOCKED.")
        if hDev then fs.close(hDev) end; return
    end

    KBL.SetVar(tDisk, nOff, sKey, sVal)
    print(string.format("Set %s = %s", sKey, sVal))
    if hDev then fs.close(hDev) end
    return
end

-- ── CLEAR-VARS ──

if sSubcmd == "clear-vars" then
    local tDisk, nOff, _, _, tHdr, hDev = findKbl(args[2])
    if not tDisk then die("No KBL partition."); return end
    tHdr.sInlineVars = ""
    KBL.WriteHeader(tDisk, nOff, tHdr)
    print("Inline variables cleared.")
    if hDev then fs.close(hDev) end
    return
end

-- ── INFO ──

if sSubcmd == "info" then
    local tDisk, nOff, nSz, tRdb, tHdr, hDev = findKbl(args[2])
    if not tDisk then die("No KBL partition."); return end

    print("KBL Partition — Detailed Info")
    print("═══════════════════════════════════════")
    print(string.format("  Device:         %s", tDisk._sPath or "?"))
    print(string.format("  Sector size:    %d bytes", tDisk.sectorSize))
    print(string.format("  Part offset:    sector %d", nOff))
    print(string.format("  Part size:      %d sectors (%s)", nSz, fmtSz(nSz * tDisk.sectorSize)))
    print("")

    if tHdr then
        print("  Header:")
        print(string.format("    Magic:        %s", "AXKB"))
        print(string.format("    Version:      %d", tHdr.nVersion or 0))
        print(string.format("    Config:       0x%02X (%s)", tHdr.nConfig or 0, fmtFlags(tHdr.nConfig or 0)))
        print(string.format("    Header CRC:   %s", tHdr.bCrcOk and "\27[32mOK\27[37m" or "\27[31mFAILED\27[37m"))
        print("")
        print("  Code:")
        print(string.format("    Size:         %d bytes", tHdr.nCodeSize or 0))
        print(string.format("    CRC32:        0x%08X", tHdr.nCodeCrc or 0))
        print(string.format("    Start sector: %d (abs: %d)", tHdr.nCodeStart or 0, nOff + (tHdr.nCodeStart or 0)))
        print(string.format("    Sectors:      %d", tHdr.nCodeCount or 0))

        if tHdr.nCodeSize > 0 then
            -- Verify code CRC
            local sCode = KBL.ReadCode(tDisk, nOff, tHdr)
            if sCode then
                print(string.format("    Verify:       \27[32mOK (%d bytes read)\27[37m", #sCode))
            else
                print(string.format("    Verify:       \27[31mFAILED\27[37m"))
            end
        else
            print("    \27[33m(no shell installed)\27[37m")
        end

        print("")
        print("  Counters:")
        print(string.format("    Boot attempts:  %d", tHdr.nBootAttempts or 0))
        print(string.format("    Last enter:     %d", tHdr.nLastEnter or 0))
        print(string.format("    Kernel fails:   %d", tHdr.nKernelFails or 0))

        print("")
        print("  Variable storage:")
        print(string.format("    Var start:      sector %d (abs: %d)", tHdr.nVarStart or 0, nOff + (tHdr.nVarStart or 0)))
        print(string.format("    Var sectors:    %d", tHdr.nVarCount or 0))
        local tVars = KBL.UnpackVars(tHdr.sInlineVars)
        local nVars = 0
        for _ in pairs(tVars) do nVars = nVars + 1 end
        print(string.format("    Inline vars:    %d entry(ies)", nVars))
        for k, v in pairs(tVars) do
            print(string.format("      %s = %s", k, v))
        end
    else
        print("  \27[31mHeader invalid or uninitialized.\27[37m")
        print("  Run: kbl install")
    end

    if tRdb then
        print("")
        print("  RDB context:")
        print(string.format("    Label:          %s", tRdb.label or "?"))
        print(string.format("    Generation:     %d", tRdb.generation or 0))
        print(string.format("    Partitions:     %d", #tRdb.partitions))
    end

    if hDev then fs.close(hDev) end
    return
end

-- Unknown subcommand
die("Unknown subcommand: " .. tostring(sSubcmd))
showUsage()