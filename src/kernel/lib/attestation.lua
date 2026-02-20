-- /lib/attestation.lua
-- Machine Remote Attestation Client
-- Talks to pki.axis-os.ru/api/attest.php

local component = require("component")
local computer   = require("computer")
local serial     = require("serialization")
local fs         = require("filesystem")

local oCrypto = require("crypto")

local oAttest = {}

-- ══════════════════════════════════════════
--  MACHINE BINDING (hardware fingerprint)
-- ══════════════════════════════════════════
function oAttest.computeBinding()
    -- Deterministic fingerprint from hardware components
    local parts = {}
    parts[#parts+1] = computer.address()

    -- Add all component addresses for stronger binding
    for addr, ctype in component.list() do
        parts[#parts+1] = addr .. ":" .. ctype
    end
    table.sort(parts) -- deterministic order

    local raw = table.concat(parts, "|")
    local dataCard = component.data
    if dataCard and dataCard.sha256 then
        return oCrypto.Hash(raw) -- SHA-256 of all hardware
    end
    -- Fallback: just use computer address
    return computer.address()
end

-- ══════════════════════════════════════════
--  KERNEL HASH
-- ══════════════════════════════════════════
function oAttest.hashKernel(sKernelPath)
    sKernelPath = sKernelPath or "/init.lua"
    local f = io.open(sKernelPath, "r")
    if not f then return nil, "Cannot read kernel: " .. sKernelPath end
    local data = f:read("*a")
    f:close()
    return oCrypto.Hash(data)
end

-- ══════════════════════════════════════════
--  MANIFEST (hash all critical files)
-- ══════════════════════════════════════════
function oAttest.generateManifest(tPaths)
    -- Default critical paths if none specified
    tPaths = tPaths or {
        "/init.lua",
        "/lib/crypto.lua",
        "/lib/attestation.lua",
        "/lib/dkms_sec.lua",
        "/usr/commands/sign.lua",
        "/usr/commands/secureboot.lua",
        "/etc/pki.cfg",
    }

    local manifest = {
        version = 1,
        timestamp = os.time(),
        machine = computer.address(),
        files = {}
    }

    for _, path in ipairs(tPaths) do
        if fs.exists(path) then
            local f = io.open(path, "r")
            if f then
                local data = f:read("*a")
                f:close()
                manifest.files[path] = {
                    hash = oCrypto.Hash(data),
                    size = #data
                }
            end
        end
    end

    return manifest
end

function oAttest.saveManifest(manifest, sPath)
    sPath = sPath or "/etc/manifest.dat"
    local f = io.open(sPath, "w")
    if not f then return false, "Cannot write " .. sPath end
    f:write(serial.serialize(manifest))
    f:close()
    return true
end

function oAttest.loadManifest(sPath)
    sPath = sPath or "/etc/manifest.dat"
    local f = io.open(sPath, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return serial.unserialize(data)
end

function oAttest.verifyManifest(manifest)
    if not manifest or not manifest.files then return false, "No manifest" end
    local failures = {}

    for path, info in pairs(manifest.files) do
        if not fs.exists(path) then
            failures[#failures+1] = {path = path, reason = "MISSING"}
        else
            local f = io.open(path, "r")
            if f then
                local data = f:read("*a")
                f:close()
                local currentHash = oCrypto.Hash(data)
                if currentHash ~= info.hash then
                    failures[#failures+1] = {
                        path = path,
                        reason = "MODIFIED",
                        expected = info.hash:sub(1,16),
                        actual = currentHash:sub(1,16)
                    }
                end
            end
        end
    end

    if #failures > 0 then
        return false, failures
    end
    return true
end

-- ══════════════════════════════════════════
--  REMOTE ATTESTATION (talk to server)
-- ══════════════════════════════════════════
function oAttest.attest(oPkiCfg)
    local inet = component.internet
    if not inet then return nil, "No internet card" end

    local baseUrl = oPkiCfg.pki_url or "https://pki.axis-os.ru/api"
    local attestUrl = baseUrl .. "/attest.php"

    -- Step 1: Get challenge
    local challengeBody = '{"action":"challenge","machine_id":"' .. computer.address() .. '"}'

    local handle = inet.request(attestUrl, challengeBody, {
        ["Content-Type"] = "application/json"
    })
    if not handle then return nil, "Connection failed" end

    -- Read response (with timeout)
    local resp = ""
    local deadline = computer.uptime() + 10
    while true do
        local chunk = handle.read()
        if chunk then
            resp = resp .. chunk
        elseif chunk == nil then
            break -- EOF
        end
        if computer.uptime() > deadline then
            handle.close()
            return nil, "Timeout on challenge"
        end
        os.sleep(0.05)
    end
    handle.close()

    local challenge = serial.unserialize(resp)
        or require("json") and require("json").decode(resp)
    if not challenge or not challenge.nonce then
        return nil, "Invalid challenge response: " .. resp:sub(1, 100)
    end

    -- Step 2: Compute attestation data
    local binding = oAttest.computeBinding()
    local kernelHash = oAttest.hashKernel(oPkiCfg.kernel_path or "/init.lua")

    -- Load our keys
    local privKeyB64 = oCrypto.LoadKey("/etc/signing/private.key")
    local pubKeyB64  = oCrypto.LoadKey("/etc/signing/public.key")
    if not privKeyB64 then return nil, "No signing keys — run: sign -g" end

    local privKey = oCrypto.DeserializeKey(privKeyB64, "ec-private")
    if not privKey then return nil, "Failed to deserialize private key" end

    -- Sign the nonce
    local sig = oCrypto.Sign(privKey, challenge.nonce)
    if not sig then return nil, "Signing failed" end

    -- Check manifest integrity
    local manifest = oAttest.loadManifest()
    local sealed = (manifest ~= nil)
    local verified = false
    if sealed then
        verified = oAttest.verifyManifest(manifest)
    end

    -- Step 3: Send attestation
    -- Need to build JSON manually (no json.encode available everywhere)
    local attestBody = string.format(
        '{"action":"attest","challenge_id":"%s","nonce":"%s",' ..
        '"machine_binding":"%s","kernel_hash":"%s",' ..
        '"public_key":"%s","signature":"%s",' ..
        '"sealed":%s,"verified":%s}',
        challenge.challenge_id,
        challenge.nonce,
        binding,
        kernelHash or "unknown",
        pubKeyB64 or "",
        sig or "",
        tostring(sealed),
        tostring(verified)
    )

    local handle2 = inet.request(attestUrl, attestBody, {
        ["Content-Type"] = "application/json"
    })
    if not handle2 then return nil, "Attestation request failed" end

    local resp2 = ""
    deadline = computer.uptime() + 10
    while true do
        local chunk = handle2.read()
        if chunk then resp2 = resp2 .. chunk
        elseif chunk == nil then break end
        if computer.uptime() > deadline then handle2.close(); return nil, "Timeout" end
        os.sleep(0.05)
    end
    handle2.close()

    -- Parse result
    -- Try json decode or serialization.unserialize
    local result
    local jOk, json = pcall(require, "json")
    if jOk and json.decode then
        result = json.decode(resp2)
    else
        -- Ghetto JSON parse for simple response
        result = {}
        result.status = resp2:match('"status"%s*:%s*"([^"]+)"')
        result.session_token = resp2:match('"session_token"%s*:%s*"([^"]+)"')
        result.trust_level = resp2:match('"trust_level"%s*:%s*"([^"]+)"')
        result.reason = resp2:match('"reason"%s*:%s*"([^"]+)"')
    end

    return result
end

-- ══════════════════════════════════════════
--  SAVE/LOAD ATTESTATION STATE
-- ══════════════════════════════════════════
function oAttest.saveState(tState)
    local f = io.open("/etc/attestation.state", "w")
    if not f then return false end
    f:write(serial.serialize(tState))
    f:close()
    return true
end

function oAttest.loadState()
    local f = io.open("/etc/attestation.state", "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return serial.unserialize(data)
end

return oAttest