--
-- /usr/commands/secureboot.lua
-- AxisOS SecureBoot Management Tool (Ring 3 safe)
--
-- EEPROM flash operations are handled by BIOS Setup (DEL at boot).
-- This command manages filesystem-based security state only.
--

local fs = require("filesystem")
local crypto = require("crypto")
local tArgs = env.ARGS or {}

local C = {
    R="\27[37m", GRN="\27[32m", RED="\27[31m",
    CYN="\27[36m", YLW="\27[33m", GRY="\27[90m",
    MAG="\27[35m", BLU="\27[34m",
}

-- crypto.Init() works at Ring 3 via module cache
-- (first loaded by a Ring 1-2 process that has component access)
local bCryptoOk, nTier = crypto.Init()

local function hex(s)
    if not s then return "" end
    local t = {}
    for i = 1, math.min(#s, 64) do
        t[i] = string.format("%02x", s:byte(i))
    end
    return table.concat(t)
end

local function readFile(sPath)
    local h = fs.open(sPath, "r")
    if not h then return nil end
    local chunks = {}
    while true do
        local s = fs.read(h, math.huge)
        if not s then break end
        chunks[#chunks+1] = s
    end
    fs.close(h)
    return table.concat(chunks)
end

local function fileExists(sPath)
    local h = fs.open(sPath, "r")
    if h then fs.close(h); return true end
    return false
end

-- Machine binding from computer.address() — available at Ring 3
local function computeBinding()
    if not bCryptoOk then return nil end
    return hex(crypto.SHA256(computer.address()))
end

-- Read secureboot config from loader.cfg (filesystem, no EEPROM)
local function readLoaderSecureboot()
    local sData = readFile("/boot/loader.cfg")
    if not sData then return {} end
    local f = load(sData, "loader.cfg", "t", {})
    if not f then return {} end
    local ok, cfg = pcall(f)
    if ok and type(cfg) == "table" then return cfg.secureboot or {} end
    return {}
end

local sCmd = tArgs[1]

-- =============================================
-- STATUS
-- =============================================
if not sCmd or sCmd == "status" then
    local sbCfg = readLoaderSecureboot()
    local sModes = {"Disabled", "Warn Only", "Enforce"}
    print(C.CYN .. "=== AxisOS SecureBoot Status ===" .. C.R)
    print("")

    print("  Data Card:     " .. (bCryptoOk and
        (C.GRN .. "Tier " .. nTier .. C.R) or
        (C.RED .. "NOT FOUND" .. C.R)))

    local nMode = sbCfg.mode or 0
    local modeC = nMode == 0 and C.YLW or (nMode == 1 and C.YLW or C.GRN)
    print("  SecureBoot:    " .. modeC .. (sModes[nMode+1] or "?") .. C.R)

    local sBind = computeBinding()
    print("  Binding:       " .. (sBind and
        (C.MAG .. sBind:sub(1,24) .. "..." .. C.R) or
        (C.GRY .. "(no data card)" .. C.R)))

    if bCryptoOk then
        local sKernel = readFile("/kernel.lua")
        if sKernel then
            local sKH = hex(crypto.SHA256(sKernel))
            print("  Kernel Hash:   " .. C.CYN .. sKH:sub(1,24) .. "..." .. C.R)
        else
            print("  Kernel Hash:   " .. C.RED .. "not found" .. C.R)
        end
    else
        print("  Kernel Hash:   " .. C.GRY .. "(no data card)" .. C.R)
    end

    local bKeys = fileExists("/etc/signing/private.key") and fileExists("/etc/signing/public.key")
    print("  Signing Keys:  " .. (bKeys and
        (C.GRN .. "Present" .. C.R) or
        (C.YLW .. "Missing" .. C.R)))

    if bKeys and bCryptoOk then
        local sPub = readFile("/etc/signing/public.key")
        if sPub then
            local sFp = crypto.Encode64(crypto.SHA256(sPub))
            print("  PK Fingerprint:" .. C.MAG .. " " .. (sFp and sFp:sub(1,24) .. "..." or "?") .. C.R)
        end
    end

    print("  Boot Manifest: " .. (fileExists("/boot/manifest.sig") and
        (C.GRN .. "Present" .. C.R) or
        (C.YLW .. "Missing" .. C.R)))

    print("")
    print(C.GRY .. "  EEPROM flash: reboot → DEL → SecureBoot & PKI" .. C.R)

-- =============================================
-- KEYGEN
-- =============================================
elseif sCmd == "keygen" then
    if not bCryptoOk then print(C.RED .. "Data card required." .. C.R); return end
    if nTier < 3 then
        print(C.RED .. "Tier 3 data card required. (Current: Tier " .. nTier .. ")" .. C.R); return
    end
    print(C.CYN .. "Generating ECDSA-384 key pair..." .. C.R)

    local pub, priv = crypto.GenerateKeyPair(384)
    if not pub or not priv then print(C.RED .. "Generation failed!" .. C.R); return end

    local sPubB64, sPrivB64 = crypto.SerializeKey(pub), crypto.SerializeKey(priv)
    if not sPubB64 or not sPrivB64 then print(C.RED .. "Serialization failed!" .. C.R); return end

    fs.mkdir("/etc"); fs.mkdir("/etc/signing")
    local h1 = fs.open("/etc/signing/private.key", "w")
    if h1 then fs.write(h1, sPrivB64); fs.close(h1) end
    local h2 = fs.open("/etc/signing/public.key", "w")
    if h2 then fs.write(h2, sPubB64); fs.close(h2) end
    fs.chmod("/etc/signing/private.key", 600)

    local sFp = crypto.Encode64(crypto.SHA256(sPubB64))
    print(C.GRN .. "[OK]" .. C.R .. " Keys saved to /etc/signing/")
    print("  Fingerprint: " .. C.MAG .. (sFp or "?") .. C.R)

-- =============================================
-- KEYDELETE
-- =============================================
elseif sCmd == "keydelete" then
    fs.remove("/etc/signing/private.key")
    fs.remove("/etc/signing/public.key")
    print(C.GRN .. "Keys deleted." .. C.R)

-- =============================================
-- BIND
-- =============================================
elseif sCmd == "bind" then
    local sBind = computeBinding()
    if sBind then
        print(C.GRN .. "[OK]" .. C.R .. " Machine binding: " .. C.MAG .. sBind:sub(1,32) .. "..." .. C.R)
    else
        print(C.RED .. "Data card required." .. C.R)
    end

-- =============================================
-- HASH
-- =============================================
elseif sCmd == "hash" then
    if not bCryptoOk then print(C.RED .. "Data card required." .. C.R); return end
    local sKernel = readFile("/kernel.lua")
    if not sKernel then print(C.RED .. "/kernel.lua not found" .. C.R); return end
    print(C.GRN .. "[OK]" .. C.R .. " Kernel hash: " .. C.CYN .. hex(crypto.SHA256(sKernel)):sub(1,32) .. "..." .. C.R)

-- =============================================
-- ENABLE / DISABLE (delegate to BIOS Setup)
-- =============================================
elseif sCmd == "enable" or sCmd == "disable" then
    local sVerb = sCmd == "enable" and "enable" or "disable"
    print(C.YLW .. "EEPROM flash requires BIOS Setup." .. C.R)
    print("")
    print("  1. Reboot the machine")
    print("  2. Press " .. C.CYN .. "DEL" .. C.R .. " during boot splash")
    print("  3. Navigate to " .. C.CYN .. "SecureBoot & PKI" .. C.R)
    print("  4. Select " .. C.CYN .. string.upper(sVerb) .. " SecureBoot" .. C.R)
    if sCmd == "enable" then
        print("")
        print(C.GRY .. "  Pre-requisites:" .. C.R)
        print(C.GRY .. "    secureboot keygen     (signing keys)" .. C.R)
        print(C.GRY .. "    manifest -g           (boot manifest)" .. C.R)
    end

-- =============================================
-- PROVISION (guided checklist)
-- =============================================
elseif sCmd == "provision" then
    print(C.CYN .. "=== SecureBoot Provisioning Checklist ===" .. C.R)
    print("")

    local nStep = 0
    local function step(bDone, sLabel, sHint)
        nStep = nStep + 1
        local sIcon = bDone and (C.GRN .. "✓") or (C.RED .. "✗")
        print(string.format("  %s%s %s[%d]%s %s", sIcon, C.R, C.CYN, nStep, C.R, sLabel))
        if not bDone and sHint then print("       " .. C.GRY .. sHint .. C.R) end
    end

    step(bCryptoOk and nTier >= 3, "Data card (Tier 3)", "Install a Tier 3 data card")

    local bKeys = fileExists("/etc/signing/private.key") and fileExists("/etc/signing/public.key")
    step(bKeys, "Signing keys generated", "Run: secureboot keygen")

    local bManifest = fileExists("/boot/manifest.sig")
    step(bManifest, "Boot manifest created", "Run: manifest -g")

    local bKernelOk = false
    if bCryptoOk then
        local sK = readFile("/kernel.lua")
        bKernelOk = sK ~= nil and #sK > 100
    end
    step(bKernelOk, "Kernel present and hashable", "Ensure /kernel.lua exists")

    print("")
    local bReady = bCryptoOk and nTier >= 3 and bKeys and bKernelOk
    if bReady then
        print(C.GRN .. "  All pre-checks passed." .. C.R)
        print("  Reboot → DEL → SecureBoot & PKI → ENABLE")
    else
        print(C.RED .. "  Not ready. Complete the steps marked ✗ above." .. C.R)
    end

-- =============================================
-- PURGE (filesystem only, no EEPROM)
-- =============================================
elseif sCmd == "purge" then
    print(C.RED .. "=== PURGE SECURITY DATA ===" .. C.R)
    print("  This will delete: signing keys, machine.id, boot manifest")
    print(C.YLW .. "  EEPROM is NOT modified. Use BIOS Setup for that." .. C.R)
    print("")
    io.write(C.RED .. "Type 'PURGE' to confirm: " .. C.R)
    if io.read() ~= "PURGE" then print("Aborted."); return end

    fs.remove("/etc/signing/private.key")
    fs.remove("/etc/signing/public.key")
    fs.remove("/etc/machine.id")
    fs.remove("/boot/manifest.sig")
    print(C.GRN .. "Filesystem security data purged." .. C.R)

-- =============================================
-- HELP
-- =============================================
else
    print(C.CYN .. "secureboot" .. C.R .. " — SecureBoot & PKI Management")
    print("")
    print("  secureboot status       Current security state")
    print("  secureboot keygen       Generate ECDSA key pair")
    print("  secureboot keydelete    Delete signing keys")
    print("  secureboot bind         Compute machine binding")
    print("  secureboot hash         Hash current kernel")
    print("  secureboot provision    Guided checklist")
    print("  secureboot purge        Remove filesystem security data")
    print("")
    print(C.GRY .. "  EEPROM operations (enable/disable/flash):" .. C.R)
    print(C.GRY .. "    Reboot → DEL → BIOS Setup → SecureBoot & PKI" .. C.R)
end