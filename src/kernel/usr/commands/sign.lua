-- /usr/commands/sign.lua
-- Sign a driver file with your ECDSA private key
--
-- Usage:
--   sign <driver_path>                 Sign with default key
--   sign -g                            Generate new key pair
--   sign -r                            Register public key with cloud PKI
--   sign -k <keyfile> <driver_path>    Sign with specific key
--

local fs = require("filesystem")
local crypto = require("crypto")
local sys = require("syscall")
local tArgs = env.ARGS or {}

local C = {R="\27[37m", GRN="\27[32m", RED="\27[31m", CYN="\27[36m", YLW="\27[33m", GRY="\27[90m"}

local KEY_DIR = "/etc/signing"
local PRIV_KEY_FILE = KEY_DIR .. "/private.key"
local PUB_KEY_FILE = KEY_DIR .. "/public.key"

-- Init crypto
local bOk, nTier = crypto.Init()
if not bOk then
    print(C.RED .. "ERROR: Data card not found. Cannot sign." .. C.R)
    return
end
if nTier < 3 then
    print(C.RED .. "ERROR: Tier 3 data card required for signing. (Current: Tier " .. nTier .. ")" .. C.R)
    return
end

-- === GENERATE KEY PAIR ===
if tArgs[1] == "-g" or tArgs[1] == "--generate" then
    print(C.CYN .. "Generating ECDSA-384 key pair..." .. C.R)

    local oPub, oPriv = crypto.GenerateKeyPair(384)
    if not oPub or not oPriv then
        print(C.RED .. "Key generation failed!" .. C.R)
        return
    end

    -- Serialize keys (may fail if data card lacks serialize support)
    local sPrivB64, sPrivErr = crypto.SerializeKey(oPriv)
    local sPubB64, sPubErr   = crypto.SerializeKey(oPub)

    if not sPrivB64 or not sPubB64 then
        print(C.RED .. "Key serialization failed!" .. C.R)
        print(C.RED .. "  " .. tostring(sPrivErr or sPubErr) .. C.R)
        print(C.YLW .. "  Your data card does not support key persistence." .. C.R)
        print(C.YLW .. "  ECDSA signing requires a data card with serialize/deserializeKey." .. C.R)
        return
    end

    -- Create directory
    fs.mkdir(KEY_DIR)

    -- Save private key
    local hPriv = fs.open(PRIV_KEY_FILE, "w")
    if hPriv then
        fs.write(hPriv, sPrivB64)
        fs.close(hPriv)
        fs.chmod(PRIV_KEY_FILE, 600)  -- owner-only
        print(C.GRN .. "[OK]" .. C.R .. " Private key: " .. PRIV_KEY_FILE)
    end

    -- Save public key
    local hPub = fs.open(PUB_KEY_FILE, "w")
    if hPub then
        fs.write(hPub, sPubB64)
        fs.close(hPub)
        print(C.GRN .. "[OK]" .. C.R .. " Public key:  " .. PUB_KEY_FILE)
    end

    -- Show fingerprint
    local sFp = crypto.Encode64(crypto.SHA256(sPubB64))
    print("")
    print(C.YLW .. "Fingerprint: " .. C.R .. sFp)
    print(C.GRY .. "Register this key: sign -r" .. C.R)
    return
end

-- === REGISTER KEY WITH CLOUD ===
if tArgs[1] == "-r" or tArgs[1] == "--register" then
    print(C.CYN .. "Registering public key with PKI..." .. C.R)
    
    local hPub = fs.open(PUB_KEY_FILE, "r")
    if not hPub then
        print(C.RED .. "No public key found. Run: sign -g" .. C.R)
        return
    end
    local sPubB64 = fs.read(hPub, math.huge)
    fs.close(hPub)
    
    local pki = require("pki_client")
    pki.LoadConfig()
    
    local bRegOk, sMsg = pki.RegisterKey(sPubB64, "ECDSA-384")
    if bRegOk then
        print(C.GRN .. "[OK]" .. C.R .. " Key submitted for approval")
        print(C.GRY .. "An admin must approve it on pki.axis-os.ru" .. C.R)
    else
        print(C.RED .. "[FAIL]" .. C.R .. " " .. tostring(sMsg))
    end
    return
end

-- === SIGN A DRIVER ===
local sDriverPath = tArgs[1]
if tArgs[1] == "-k" then
    PRIV_KEY_FILE = tArgs[2]
    PUB_KEY_FILE = tArgs[2]:gsub("private", "public") -- convention
    sDriverPath = tArgs[3]
end

if not sDriverPath then
    print(C.CYN .. "sign" .. C.R .. " - AxisOS Driver Signing Tool")
    print("  sign <driver>     Sign a driver file")
    print("  sign -g           Generate ECDSA key pair")
    print("  sign -r           Register key with cloud PKI")
    print("  sign -k <key> <driver>  Sign with specific key")
    return
end

-- Resolve path
if sDriverPath:sub(1,1) ~= "/" then
    sDriverPath = (env.PWD or "/") .. "/" .. sDriverPath
end

-- Read driver code
local hDrv = fs.open(sDriverPath, "r")
if not hDrv then
    print(C.RED .. "File not found: " .. sDriverPath .. C.R); return
end
local sCode = fs.read(hDrv, math.huge)
fs.close(hDrv)

-- Strip any existing signature block
local tLines = {}
for line in sCode:gmatch("[^\n]+") do
    if not line:match("^%-%-@SIGNATURE:") and
       not line:match("^%-%-@SIGNER:") and
       not line:match("^%-%-@HASH:") then
        tLines[#tLines + 1] = line
    end
end
local sCleanCode = table.concat(tLines, "\n")

-- Load private key
local hPriv = fs.open(PRIV_KEY_FILE, "r")
if not hPriv then
    print(C.RED .. "No private key. Run: sign -g" .. C.R); return
end
local sPrivB64 = fs.read(hPriv, math.huge)
fs.close(hPriv)
local oPrivKey = crypto.DeserializeKey(sPrivB64, "ec-private")
if not oPrivKey then
    print(C.RED .. "Cannot load private key (format incompatible or data card lacks deserializeKey)." .. C.R)
    return
end
-- Load public key for fingerprint
local hPub = fs.open(PUB_KEY_FILE, "r")
local sPubB64 = hPub and fs.read(hPub, math.huge) or ""
if hPub then fs.close(hPub) end
local sFingerprint = crypto.Encode64(crypto.SHA256(sPubB64))

-- Compute hash and sign
local sHash = crypto.Encode64(crypto.SHA256(sCleanCode))
local sSig = crypto.Sign(sCleanCode, oPrivKey)
local sSigB64 = crypto.Encode64(sSig)


-- Check approval status (non-blocking warning)
local bApprovalChecked = false
pcall(function()
    local pki = require("pki_client")
    if pki.LoadConfig() then
        local hPubCheck = fs.open(PUB_KEY_FILE, "r")
        if hPubCheck then
            local sPubCheck = fs.read(hPubCheck, math.huge)
            fs.close(hPubCheck)
            if sPubCheck then
                local sStatus = pki.CheckKeyStatus(sPubCheck)
                bApprovalChecked = true
                if sStatus ~= "approved" then
                    print(C.YLW .. "WARNING: Key status is '" .. tostring(sStatus) .. "' (not approved)" .. C.R)
                    print(C.YLW .. "  Signed files will be REJECTED by enforcement policy (level 2)." .. C.R)
                    print(C.YLW .. "  Register with: sign -r    Then wait for admin approval." .. C.R)
                    print("")
                end
            end
        end
    end
end)


-- Write signed file
local hOut = fs.open(sDriverPath, "w")
if not hOut then
    print(C.RED .. "Cannot write to " .. sDriverPath .. C.R); return
end
fs.write(hOut, sCleanCode .. "\n")
fs.write(hOut, "--@HASH:" .. sHash .. "\n")
fs.write(hOut, "--@SIGNER:" .. sFingerprint .. "\n")
fs.write(hOut, "--@SIGNATURE:" .. sSigB64 .. "\n")
fs.close(hOut)

print(C.GRN .. "[SIGNED]" .. C.R .. " " .. sDriverPath)
print("  Hash:    " .. sHash:sub(1, 16) .. "...")
print("  Signer:  " .. sFingerprint:sub(1, 16) .. "...")
print("  Sig:     " .. sSigB64:sub(1, 16) .. "...")

