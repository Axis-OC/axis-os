-- /usr/commands/manifest.lua
-- Generate and verify signed boot manifests
--
-- A manifest is a signed list of (path, sha256_hash) pairs
-- for every critical system file. The EEPROM stores the
-- manifest's own hash, and the kernel verifies it at boot.
--
-- Usage:
--   manifest --generate     Create and sign manifest
--   manifest --verify       Verify current system against manifest
--   manifest --show         Display manifest contents
--

local fs = require("filesystem")
local crypto = require("crypto")
local tArgs = env.ARGS or {}

local C = {
  R="\27[37m", GRN="\27[32m", RED="\27[31m",
  CYN="\27[36m", YLW="\27[33m", GRY="\27[90m"
}

local MANIFEST_PATH = "/boot/manifest.sig"
local MANIFEST_PATHS = {
    -- Critical boot chain
    "/kernel.lua",
    "/lib/pipeline_manager.lua",
    "/system/dkms.lua",
    "/system/driverdispatch.lua",
    
    -- Security infrastructure
    "/lib/ob_manager.lua",
    "/lib/ke_ipc.lua",
    "/lib/preempt.lua",
    "/lib/registry.lua",
    "/lib/crypto.lua",
    "/lib/pki_client.lua",
    "/sys/security/dkms_sec.lua",
    
    -- Driver kit
    "/system/lib/dk/shared_structs.lua",
    "/system/lib/dk/kmd_api.lua",
    "/system/lib/dk/common_api.lua",
    
    -- Core drivers
    "/drivers/tty.sys.lua",
    "/drivers/gpu.sys.lua",
    
    -- Init
    "/bin/init.lua",
    "/bin/sh.lua",
    
    -- Config (integrity-sensitive)
    "/etc/passwd.lua",
    "/etc/perms.lua",
    "/etc/pki.cfg",
}

local bOk, nTier = crypto.Init()
if not bOk then
    print(C.RED .. "No data card." .. C.R)
    return
end

local function hashFile(sPath)
    local h = fs.open(sPath, "r")
    if not h then return nil end
    local chunks = {}
    while true do
        local d = fs.read(h, 8192)
        if not d then break end
        chunks[#chunks+1] = d
    end
    fs.close(h)
    local sData = table.concat(chunks)
    local sHash = crypto.SHA256(sData)
    return crypto.Encode64(sHash), #sData
end

-- === GENERATE ===
if tArgs[1] == "--generate" or tArgs[1] == "-g" then
    print(C.CYN .. "Generating boot manifest..." .. C.R)
    print("")
    
    local tEntries = {}
    local nTotal = 0
    local nMissing = 0
    
    for _, sPath in ipairs(MANIFEST_PATHS) do
        local sHash, nSize = hashFile(sPath)
        if sHash then
            tEntries[#tEntries+1] = {
                path = sPath,
                hash = sHash,
                size = nSize
            }
            nTotal = nTotal + 1
            print(C.GRN .. "  ✓ " .. C.R .. sPath)
        else
            nMissing = nMissing + 1
            print(C.YLW .. "  ? " .. C.R .. sPath .. C.GRY .. " (missing)" .. C.R)
        end
    end
    
    -- Build manifest document
    local tLines = {}
    tLines[1] = "-- AxisOS Boot Manifest"
    tLines[2] = "-- Generated: " .. os.date("%Y-%m-%d %H:%M:%S")
    tLines[3] = "-- Files: " .. nTotal
    tLines[4] = "return {"
    
    for _, e in ipairs(tEntries) do
        tLines[#tLines+1] = string.format(
            '  {path="%s", hash="%s", size=%d},',
            e.path, e.hash, e.size)
    end
    tLines[#tLines+1] = "}"
    
    local sManifest = table.concat(tLines, "\n")
    
    -- Sign manifest if Tier 3
    local sSigBlock = ""
    if nTier >= 3 then
        local hPriv = fs.open("/etc/signing/private.key", "r")
        if hPriv then
            local sPrivB64 = fs.read(hPriv, math.huge)
            fs.close(hPriv)
            local oPrivKey = crypto.DeserializeKey(sPrivB64, "ec-private")
            if oPrivKey then
                local sSig = crypto.Sign(sManifest, oPrivKey)
                local sSigB64 = crypto.Encode64(sSig)
                
                -- Get signer fingerprint
                local hPub = fs.open("/etc/signing/public.key", "r")
                local sPub = hPub and fs.read(hPub, math.huge) or ""
                if hPub then fs.close(hPub) end
                local sFp = crypto.Encode64(crypto.SHA256(sPub))
                
                sSigBlock = "\n--@MANIFEST_SIG:" .. sSigB64 ..
                            "\n--@MANIFEST_SIGNER:" .. sFp
                print("")
                print(C.GRN .. "  Manifest SIGNED" .. C.R)
            end
        else
            print(C.YLW .. "  No signing key. Manifest unsigned." .. C.R)
        end
    end
    
    -- Write
    fs.mkdir("/boot")
    local hOut = fs.open(MANIFEST_PATH, "w")
    if hOut then
        fs.write(hOut, sManifest .. sSigBlock .. "\n")
        fs.close(hOut)
        print("")
        print(C.GRN .. "Manifest written to " .. MANIFEST_PATH .. C.R)
        print("  Files: " .. nTotal .. "  Missing: " .. nMissing)
    else
        print(C.RED .. "Cannot write manifest!" .. C.R)
    end
    return
end

-- === VERIFY ===
if tArgs[1] == "--verify" or tArgs[1] == "-v" then
    print(C.CYN .. "Verifying system against manifest..." .. C.R)
    print("")
    
    local hMan = fs.open(MANIFEST_PATH, "r")
    if not hMan then
        print(C.RED .. "No manifest found at " .. MANIFEST_PATH .. C.R)
        return
    end
    local sManifest = fs.read(hMan, math.huge)
    fs.close(hMan)
    
    -- Extract data portion (before signature block)
    local sData = sManifest:match("^(.-)%-%-@MANIFEST_SIG") or sManifest
    sData = sData:gsub("%s+$", "")  -- trim trailing whitespace
    
    -- Parse
    local fParse = load(sData, "manifest", "t", {})
    if not fParse then
        print(C.RED .. "Manifest parse error" .. C.R)
        return
    end
    local tManifest = fParse()
    
    local nOk, nFail, nMissing = 0, 0, 0
    
    for _, entry in ipairs(tManifest) do
        local sCurrentHash = hashFile(entry.path)
        if not sCurrentHash then
            nMissing = nMissing + 1
            print(C.YLW .. "  MISSING  " .. C.R .. entry.path)
        elseif sCurrentHash == entry.hash then
            nOk = nOk + 1
            print(C.GRN .. "  OK       " .. C.R .. entry.path)
        else
            nFail = nFail + 1
            print(C.RED .. "  MODIFIED " .. C.R .. entry.path)
            print(C.GRY .. "           Expected: " .. entry.hash:sub(1,16) .. "..." .. C.R)
            print(C.GRY .. "           Actual:   " .. sCurrentHash:sub(1,16) .. "..." .. C.R)
        end
    end
    
    print("")
    print(string.format("  %sOK: %d%s  |  %sMODIFIED: %d%s  |  %sMISSING: %d%s",
        C.GRN, nOk, C.R,
        nFail > 0 and C.RED or C.GRN, nFail, C.R,
        nMissing > 0 and C.YLW or C.GRN, nMissing, C.R))
    
    if nFail > 0 then
        print("")
        print(C.RED .. "  ⚠  INTEGRITY VIOLATION DETECTED" .. C.R)
        print(C.RED .. "  System files have been modified since manifest was generated." .. C.R)
    elseif nMissing > 0 then
        print(C.YLW .. "  Some files missing but no tampering detected." .. C.R)
    else
        print(C.GRN .. "  ✓ ALL FILES VERIFIED" .. C.R)
    end
    return
end

-- === SHOW ===
if tArgs[1] == "--show" or tArgs[1] == "-s" then
    local hMan = fs.open(MANIFEST_PATH, "r")
    if not hMan then print("No manifest."); return end
    print(fs.read(hMan, math.huge))
    fs.close(hMan)
    return
end

-- === HELP ===
print(C.CYN .. "manifest" .. C.R .. " - Boot integrity manifest tool")
print("  manifest -g    Generate signed manifest")
print("  manifest -v    Verify system files against manifest")
print("  manifest -s    Show manifest contents")