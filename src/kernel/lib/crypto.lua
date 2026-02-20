-- /lib/crypto.lua
-- AxisOS Cryptographic Abstraction Layer
-- Requires: Data Card (Tier 2+ for hashing, Tier 3 for ECDSA)

local oCrypto = {}

local g_oDataCard = nil
local g_nTier = 0

function oCrypto.Init()
    -- If already initialized (e.g. by a Ring 1 process that loaded this
    -- module first), return success immediately.  This prevents Ring 3
    -- callers from clobbering g_oDataCard when component/raw_component
    -- are unavailable in their sandbox.
    if g_oDataCard and g_nTier > 0 then
        return true, g_nTier
    end

    local bOk, tList = pcall(function()
        local t = {}
        for addr, ctype in component.list("data") do t[addr] = ctype end
        return t
    end)
    -- fallback for kernel context where component is raw_component
    if not bOk then
        bOk, tList = pcall(function()
            local t = {}
            for addr in raw_component.list("data") do t[addr] = "data" end
            return t
        end)
    end
    if not bOk or not tList then return false, "No data card" end
    
    for addr in pairs(tList) do
        local proxy
        pcall(function() proxy = component.proxy(addr) end)
        if not proxy then pcall(function() proxy = raw_component.proxy(addr) end) end
        if proxy then
            g_oDataCard = proxy
            -- Detect tier by available methods
            if proxy.ecdsa then g_nTier = 3
            elseif proxy.encrypt then g_nTier = 2
            else g_nTier = 1 end
            return true, g_nTier
        end
    end
    return false, "Data card proxy failed"
end

function oCrypto.GetTier() return g_nTier end

-- SHA-256 hash (Tier 1+)
function oCrypto.SHA256(sData)
    if not g_oDataCard or g_nTier < 1 then return nil, "No data card" end
    return g_oDataCard.sha256(sData)
end

-- SHA-256 hash of a file via raw filesystem
function oCrypto.HashFile(sPath, oFs)
    if not oFs then return nil, "No filesystem" end
    local h = oFs.open(sPath, "r")
    if not h then return nil, "File not found: " .. sPath end
    local tChunks = {}
    while true do
        local chunk = oFs.read(h, 8192)
        if not chunk then break end
        tChunks[#tChunks + 1] = chunk
    end
    oFs.close(h)
    local sData = table.concat(tChunks)
    return oCrypto.SHA256(sData), sData
end

-- Base64 encode/decode (Tier 1+)
function oCrypto.Encode64(sData)
    if not g_oDataCard then return nil end
    return g_oDataCard.encode64(sData)
end

function oCrypto.Decode64(sData)
    if not g_oDataCard then return nil end
    return g_oDataCard.decode64(sData)
end

-- Random bytes (Tier 2+)
function oCrypto.Random(nBytes)
    if g_nTier >= 2 then return g_oDataCard.random(nBytes) end
    -- Fallback: weak random (NOT cryptographically secure)
    local t = {}
    for i = 1, nBytes do t[i] = string.char(math.random(0, 255)) end
    return table.concat(t)
end

-- ECDSA Key Generation (Tier 3 only)
function oCrypto.GenerateKeyPair(nBits)
    if g_nTier < 3 then return nil, nil, "Tier 3 data card required" end
    local pub, priv = g_oDataCard.generateKeyPair(nBits or 384)
    return pub, priv
end

-- ECDSA Sign (Tier 3)
function oCrypto.Sign(sData, oPrivateKey)
    if not g_oDataCard or g_nTier < 3 then return nil, "Tier 3 required" end
    return g_oDataCard.ecdsa(sData, oPrivateKey)
end

-- ECDSA Verify (Tier 3)
function oCrypto.Verify(sData, sSignature, oPublicKey)
    if not g_oDataCard or g_nTier < 3 then return false end
    return g_oDataCard.ecdsa(sData, oPublicKey, sSignature)
end

-- Key serialization
function oCrypto.SerializeKey(oKey)
    if not g_oDataCard then return nil, "No data card" end
    if not oKey then return nil, "No key" end

    local bOk, sRaw = pcall(function()
        if oKey.serialize then return oKey.serialize() end
        return nil
    end)

    if bOk and type(sRaw) == "string" and #sRaw > 0 then
        return g_oDataCard.encode64(sRaw)
    end

    return nil, "key.serialize() failed — your data card keys may not support persistence"
end

function oCrypto.DeserializeKey(sB64, sType)
    if not g_oDataCard then return nil end
    if not sB64 or #sB64 == 0 then return nil end

    local bDecOk, sRaw = pcall(g_oDataCard.decode64, sB64)
    if not bDecOk or not sRaw then return nil, "Base64 decode failed" end

    if type(g_oDataCard.deserializeKey) == "function" then
        local bOk, oKey = pcall(g_oDataCard.deserializeKey, sRaw, sType or "ec-public")
        if bOk and oKey then return oKey end
        return nil, "deserializeKey failed: " .. tostring(oKey)
    end

    return nil, "Data card lacks deserializeKey()"
end

return oCrypto