--
-- /usr/commands/test_pgheal.lua
-- Verifies PatchGuard self-heal infrastructure is operational.
-- Checks golden image, KIQGR enclave, XOR hashes, check rotation.
--
local fs = require("filesystem")
local C = {R="\27[37m",G="\27[32m",E="\27[31m",Y="\27[33m",C="\27[36m",D="\27[90m"}
local nPass, nFail, nSkip = 0, 0, 0
local function pass(s) nPass=nPass+1; print(C.G.."  [PASS] "..C.R..s) end
local function fail(s) nFail=nFail+1; print(C.E.."  [FAIL] "..C.R..s) end
local function skip(s) nSkip=nSkip+1; print(C.Y.."  [SKIP] "..C.R..s) end
local function info(s) print(C.C.."  [INFO] "..C.R..s) end
local function section(s) print(""); print(C.Y.."=== "..s.." ==="..C.R) end

print(C.C.."╔═══════════════════════════════════════════╗"..C.R)
print(C.C.."║  PatchGuard Self-Heal Infrastructure Test  ║"..C.R)
print(C.C.."╚═══════════════════════════════════════════╝"..C.R)

local tPG = syscall("patchguard_status")

-- 1. PatchGuard loaded?
section("1. PatchGuard availability")

if not tPG then
    fail("patchguard_status returned nil — PatchGuard not loaded")
    print(C.E.."  → Check __load_patchguard() in kernel.lua"..C.R)
    print(C.E.."  → Verify /sys/security/patchguard.lua exists"..C.R)
    return
end
if tPG.bAvailable then
    pass("PatchGuard subsystem available")
else
    fail("PatchGuard loaded but reports unavailable")
end

-- 2. Armed state
section("2. Armed state")

if tPG.bArmed then
    pass("PatchGuard is ARMED (monitoring active)")
else
    info("PatchGuard NOT armed — normal if boot < 300 ticks")
    info("  Checks performed so far: " .. tostring(tPG.nChecksPerformed or 0))
end

-- 3. File hashes computed
section("3. Critical file hashing")

local nHashed = tPG.nCriticalFilesHashed or 0
if nHashed > 0 then
    pass(nHashed .. " critical files hashed at boot")
else
    fail("No files hashed — PatchGuard cannot detect modifications")
    info("  → Check snapshotCriticalFiles() in patchguard.lua")
    info("  → Verify fReadFile and oSha256/fSha256 are configured")
end

local nFileChecks = tPG.nFileChecksTotal or 0
local nFilePasses = tPG.nFilePassTotal or 0
local nFileFails  = tPG.nFileFailTotal or 0
info("File integrity checks: " .. nFileChecks ..
     " total, " .. nFilePasses .. " pass, " .. nFileFails .. " fail")

if nFileFails > 0 then
    fail(nFileFails .. " file(s) FAILED integrity check since boot!")
else
    if nFileChecks > 0 then
        pass("All " .. nFileChecks .. " file checks passed")
    end
end

-- 4. Golden image subsystem
section("4. Golden image (self-heal source)")

local bGoldenExists = false
local hGoldenDir = fs.list("/etc/.golden")
if hGoldenDir and type(hGoldenDir) == "table" then
    local nShadows = 0
    for _, sName in ipairs(hGoldenDir) do nShadows = nShadows + 1 end
    if nShadows > 0 then
        pass("Golden shadow directory has " .. nShadows .. " backup(s)")
        bGoldenExists = true
    else
        info("/etc/.golden/ exists but is empty")
    end
end

-- Check distribution backups (fallback)
local tCritical = {
    "/etc/.golden__kernel.lua.bak",
    "/etc/.golden__bin_init.lua.bak",
    "/etc/.golden__etc_passwd.lua.bak",
}
local nDistBackups = 0
for _, sPath in ipairs(tCritical) do
    local h = fs.open(sPath, "r")
    if h then fs.close(h); nDistBackups = nDistBackups + 1 end
end
if nDistBackups > 0 then
    pass(nDistBackups .. " distribution backup file(s) found (last-resort revert)")
    bGoldenExists = true
end

if not bGoldenExists and nHashed > 0 then
    info("No golden backups on disk — self-heal will DETECT but cannot REVERT")
    info("  → Place .bak files in /etc/ or enable shadow copies in golden_image.lua")
end

-- 5. XOR-encrypted hash storage
section("5. XOR-encrypted hash storage")

if tPG.bXorKeyActive then
    pass("XOR key active (" .. (tPG.nXorKeyBytes or 0) .. " bytes)")
    info("  Stored hashes are encrypted — memory dump useless to attacker")
else
    fail("XOR key NOT active — file hashes stored in plaintext")
    info("  → Check sPgXorKey generation in kernel.lua (needs data card or sha256)")
end

-- 6. Check function rotation
section("6. Check function rotation")

local nVariants = tPG.nCheckVariants or 0
if nVariants >= 3 then
    pass(nVariants .. " check variants (alpha/beta/gamma)")
else
    fail("Only " .. nVariants .. " variant(s) — need >= 3 for rotation")
    info("  → Verify g_tCheckVariants array in patchguard.lua")
end

-- 7. SHA-256 module
section("7. SHA-256 availability")

if tPG.bSha256Module then
    pass("Pure-Lua SHA-256 (/lib/sha256.lua) loaded")
else
    info("Using data card SHA-256 (fallback) — adequate but slower")
end

-- 8. Self-integrity
section("8. Violation counter")

local nViols = tPG.nViolations or 0
if nViols == 0 then
    pass("Zero violations since boot — integrity intact")
else
    fail(nViols .. " violation(s) detected!")
    info("  → Check /log/crash_*.dump or dmesg for details")
end

-- Summary
print("")
print(C.C.."═══════════════════════════════════════════"..C.R)
print(string.format("  %sPassed:%s %d   %sFailed:%s %d   %sSkipped:%s %d",
    C.G, C.R, nPass, nFail>0 and C.E or C.D, C.R, nFail,
    C.Y, C.R, nSkip))
if nFail == 0 then
    print(C.G.."  PatchGuard self-heal infrastructure OK."..C.R)
else
    print(C.E.."  Self-heal infrastructure has gaps — review above."..C.R)
end
print(C.C.."═══════════════════════════════════════════"..C.R)