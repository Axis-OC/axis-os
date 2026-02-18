-- /lib/pki_client.lua
-- Cloud PKI Client for AxisOS
-- Communicates with pki.axis-os.ru API

local http = require("http")
local crypto = require("crypto")

local oPki = {}

local PKI_BASE = "https://pki.axis-os.ru/api"
local g_sApiToken = nil
local g_tKeyCache = {}     -- fingerprint → {pubkey, status, cached_at}
local g_tHashCache = {}    -- sha256 → {status, signer, cached_at}
local CACHE_TTL = 3600     -- 1 hour cache

function oPki.SetToken(sToken)
    g_sApiToken = sToken
end

-- Load token from /etc/pki.cfg
function oPki.LoadConfig()
    local fs = require("filesystem")
    local h = fs.open("/etc/pki.cfg", "r")
    if not h then return false end
    local d = fs.read(h, math.huge)
    fs.close(h)
    if not d then return false end
    local f = load(d, "pki.cfg", "t", {})
    if f then
        local cfg = f()
        if cfg then
            g_sApiToken = cfg.api_token
            PKI_BASE = cfg.pki_url or PKI_BASE
            return true
        end
    end
    return false
end

-- Register a new ECDSA public key with the cloud PKI
function oPki.RegisterKey(sPublicKeyB64, sKeyType)
    if not g_sApiToken then return nil, "No API token configured" end
    
    local resp = http.request("POST", PKI_BASE .. "/register.php",
        '{"public_key":"' .. sPublicKeyB64 .. '","type":"' .. (sKeyType or "ECDSA-384") .. '"}',
        {["X-API-Token"] = g_sApiToken, ["Content-Type"] = "application/json"})
    
    if resp.code == 200 then
        return true, resp.body
    end
    return nil, resp.body or ("HTTP " .. resp.code)
end

-- Check key status (approved/pending/revoked)
function oPki.CheckKeyStatus(sPublicKeyB64)
    local resp = http.request("POST", PKI_BASE .. "/status.php",
        '{"public_key":"' .. sPublicKeyB64 .. '"}',
        {["Content-Type"] = "application/json"})
    
    if resp.code == 200 and resp.body then
        local ok, data = pcall(function()
            -- minimal JSON parse
            local status = resp.body:match('"status"%s*:%s*"([^"]+)"')
            return status
        end)
        if ok then return data end
    end
    return "unknown"
end

-- Get all approved signing keys from cloud
function oPki.FetchApprovedKeys()
    if not g_sApiToken then return nil, "No token" end
    
    local resp = http.request("POST", PKI_BASE .. "/approved_keys.php",
        '{}',
        {["X-API-Token"] = g_sApiToken, ["Content-Type"] = "application/json"})
    
    if resp.code == 200 and resp.body then
        -- Parse the JSON response (simplified)
        local tKeys = {}
        -- Each key entry: {"fingerprint":"...","public_key":"...","username":"...","status":"approved"}
        for fp, pk, user in resp.body:gmatch(
            '"fingerprint"%s*:%s*"([^"]+)"%s*,%s*"public_key"%s*:%s*"([^"]+)"%s*,%s*"username"%s*:%s*"([^"]+)"') do
            tKeys[fp] = {public_key = pk, username = user, status = "approved"}
        end
        return tKeys
    end
    return nil, "Fetch failed"
end

-- Verify a file hash against cloud manifest
function oPki.CloudVerifyHash(sHash, sFileName)
    -- Check local cache first
    local tCached = g_tHashCache[sHash]
    if tCached and (os.clock() - tCached.cached_at) < CACHE_TTL then
        return tCached.status, tCached.signer
    end
    
    if not g_sApiToken then return "offline", nil end
    
    local resp = http.request("POST", PKI_BASE .. "/verify_hash.php",
        '{"hash":"' .. sHash .. '","filename":"' .. (sFileName or "") .. '"}',
        {["X-API-Token"] = g_sApiToken, ["Content-Type"] = "application/json"})
    
    if resp.code == 200 and resp.body then
        local status = resp.body:match('"status"%s*:%s*"([^"]+)"')
        local signer = resp.body:match('"signer"%s*:%s*"([^"]*)"')
        
        if status then
            g_tHashCache[sHash] = {status = status, signer = signer, cached_at = os.clock()}
            return status, signer
        end
    end
    
    return "unverified", nil
end

-- Revoke a key
function oPki.RevokeKey(sPublicKeyB64)
    if not g_sApiToken then return nil, "No token" end
    local resp = http.request("POST", PKI_BASE .. "/revoke.php",
        '{"public_key":"' .. sPublicKeyB64 .. '"}',
        {["X-API-Token"] = g_sApiToken, ["Content-Type"] = "application/json"})
    return resp.code == 200, resp.body
end

-- Sync approved keys to local cache file
function oPki.SyncKeyStore()
    local tKeys, sErr = oPki.FetchApprovedKeys()
    if not tKeys then return false, sErr end
    
    local fs = require("filesystem")
    local sData = "-- Auto-synced PKI key store\nreturn {\n"
    for fp, tInfo in pairs(tKeys) do
        sData = sData .. string.format(
            '  ["%s"] = {public_key="%s", username="%s", status="%s"},\n',
            fp, tInfo.public_key, tInfo.username, tInfo.status)
    end
    sData = sData .. "}\n"
    
    local h = fs.open("/etc/pki_keystore.lua", "w")
    if h then
        fs.write(h, sData)
        fs.close(h)
        return true
    end
    return false, "Cannot write keystore"
end

-- Load local key store (offline fallback)
function oPki.LoadLocalKeyStore()
    local fs = require("filesystem")
    local h = fs.open("/etc/pki_keystore.lua", "r")
    if not h then return {} end
    local d = fs.read(h, math.huge)
    fs.close(h)
    if not d then return {} end
    local f = load(d, "keystore", "t", {})
    if f then return f() or {} end
    return {}
end

return oPki