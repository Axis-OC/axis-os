-- /lib/crypto.lua
-- AxisOS Cryptographic Abstraction Layer
-- Requires: Data Card (Tier 2+ for hashing, Tier 3 for ECDSA)

local oCrypto = {}

local g_oDataCard = nil
local g_nTier = 0

function oCrypto.Init()
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

-- ECDSA