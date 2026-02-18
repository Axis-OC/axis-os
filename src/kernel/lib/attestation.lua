-- /lib/attestation.lua
-- Machine Remote Attestation for AxisOS
-- Proves to the cloud that THIS specific machine is running
-- unmodified software on genuine hardware.

local crypto = require("crypto")
local http = require("http")

local oAttest = {}

local ATTEST_URL = "https://pki.axis-os.ru/api/attest.php"

--[[
  ATTESTATION FLOW:
  
  1. Machine → Cloud:  "I am machine X, give me a challenge"
  2. Cloud → Machine:  nonce (random 32 bytes, valid for 30 seconds)
  3. Machine:
     a) Collects: machine_binding, kernel_hash, component_list
     b) Signs: SHA256(nonce .. binding .. kernel_hash .. components)
     c) Signs with data card's ECDSA private key
  4. Machine → Cloud:  {signed_attestation, public_key, component_data}
  5. Cloud:
     a) Verify nonce is fresh
     b) Verify ECDSA signature with registered public key
     c) Compare kernel_hash with expected (from PKI database)
     d) Compare binding with registered machine
  6. Cloud → Machine:  {status: "attested", token: "session_token"}
  
  The session_token can then be used for:
  - Driver downloads
  - CRL updates
  - Telemetry submission
  - Certificate renewal
]]

function oAttest.CollectEvidence()
    -- Gather all measurable system state
    local bOk, nTier = crypto.Init()
    if not bOk then return nil, "No data card" end
    
    local evidence = {
        timestamp = os.clock(),
    }
    
    -- Machine binding (from boot_security if available)
    if _G.boot_security then
        evidence.machine_binding = _G.boot_security.machine_binding
        evidence.kernel_hash = _G.boot_security.kernel_hash
        evidence.data_card_addr = _G.boot_security.data_card_addr
        evidence.sealed = _G.boot_security.sealed
        evidence.verified = _G.boot_security.verified
    end
    
    -- Component inventory
    local tComponents = {}
    local bListOk, tList = pcall(function()
        local t = {}
        for addr, ctype in component.list() do
            t[addr] = ctype
        end
        return t
    end)
    if bListOk and tList then
        for addr, ctype in pairs(tList) do
            tComponents[#tComponents+1] = ctype .. ":" .. addr:sub(1,8)
        end
        table.sort(tComponents)
    end
    evidence.components = table.concat(tComponents, ",")
    
    -- Compute evidence hash
    local sEvidenceString = (evidence.machine_binding or "UNKNOWN") ..
                            (evidence.kernel_hash or "UNKNOWN") ..
                            evidence.components
    evidence.evidence_hash = crypto.Encode64(crypto.SHA256(sEvidenceString))
    
    return evidence
end

function oAttest.RequestChallenge(sMachineId)
    local resp = http.post(ATTEST_URL,
        '{"action":"challenge","machine_id":"' .. (sMachineId or "unknown") .. '"}',
        {["Content-Type"] = "application/json"})
    
    if resp.code == 200 and resp.body then
        local nonce = resp.body:match('"nonce"%s*:%s*"([^"]+)"')
        local challenge_id = resp.body:match('"challenge_id"%s*:%s*"([^"]+)"')
        return nonce, challenge_id
    end
    return nil, "Challenge request failed"
end

function oAttest.Attest(sApiToken)
    if not sApiToken then
        -- Try loading from config
        local pki = require("pki_client")
        pki.LoadConfig()
    end
    
    -- Step 1: Collect evidence
    local evidence, sErr = oAttest.CollectEvidence()
    if not evidence then return nil, sErr end
    
    -- Step 2: Get challenge from cloud
    local sNonce, sChallengeId = oAttest.RequestChallenge(
        evidence.machine_binding or "new")
    if not sNonce then return nil, "No challenge: " .. tostring(sChallengeId) end
    
    -- Step 3: Sign the evidence + nonce
    local sPayload = sNonce ..
                     (evidence.machine_binding or "") ..
                     (evidence.kernel_hash or "") ..
                     evidence.components
    
    local nTier = crypto.GetTier()
    local sSigB64 = "UNSIGNED"
    local sPubKeyB64 = ""
    
    if nTier >= 3 then
        -- Load machine signing key
        local fs = require("filesystem")
        local hPriv = fs.open("/etc/signing/private.key", "r")
        local hPub = fs.open("/etc/signing/public.key", "r")
        
        if hPriv and hPub then
            local sPriv = fs.read(hPriv, math.huge)
            sPubKeyB64 = fs.read(hPub, math.huge)
            fs.close(hPriv)
            fs.close(hPub)
            
            local oPrivKey = crypto.DeserializeKey(sPriv, "ec-private")
            if oPrivKey then
                local sSig = crypto.Sign(sPayload, oPrivKey)
                sSigB64 = crypto.Encode64(sSig)
            end
        end
    end
    
    -- Step 4: Submit attestation
    local sBody = string.format(
        '{"action":"attest","challenge_id":"%s","nonce":"%s",' ..
        '"signature":"%s","public_key":"%s",' ..
        '"machine_binding":"%s","kernel_hash":"%s",' ..
        '"components":"%s","sealed":%s,"verified":%s}',
        sChallengeId, sNonce, sSigB64, sPubKeyB64,
        evidence.machine_binding or "UNKNOWN",
        evidence.kernel_hash or "UNKNOWN",
        evidence.components,
        evidence.sealed and "true" or "false",
        evidence.verified and "true" or "false"
    )
    
    local resp = http.post(ATTEST_URL, sBody,
        {["Content-Type"] = "application/json",
         ["X-API-Token"] = sApiToken or ""})
    
    if resp.code == 200 and resp.body then
        local status = resp.body:match('"status"%s*:%s*"([^"]+)"')
        local token = resp.body:match('"session_token"%s*:%s*"([^"]+)"')
        
        if status == "attested" then
            return {
                status = "attested",
                session_token = token,
                evidence = evidence
            }
        end
        return nil, "Attestation rejected: " .. (status or "unknown")
    end
    
    return nil, "Attestation HTTP failed: " .. resp.code
end

-- Runtime integrity check — can be called periodically
function oAttest.VerifyRuntime()
    local fs = require("filesystem")
    local bOk = crypto.Init()
    if not bOk then return false, "No crypto" end
    
    local tResults = {}
    
    -- Re-hash kernel
    local sKernHash = crypto.HashFile("/kernel.lua", nil)
    if _G.boot_security and _G.boot_security.kernel_hash then
        if crypto.Encode64(sKernHash) ~= _G.boot_security.kernel_hash then
            tResults.kernel_modified = true
        end
    end
    
    -- Check manifest
    local hMan = fs.open("/boot/manifest.sig", "r")
    if hMan then
        local sManifest = fs.read(hMan, math.huge)
        fs.close(hMan)
        local sData = sManifest:match("^(.-)%-%-@MANIFEST_SIG") or sManifest
        local fParse = load(sData:gsub("%s+$", ""), "manifest", "t", {})
        if fParse then
            local tManifest = fParse()
            local nModified = 0
            for _, entry in ipairs(tManifest) do
                local h = fs.open(entry.path, "r")
                if h then
                    local d = fs.read(h, math.huge)
                    fs.close(h)
                    local sHash = crypto.Encode64(crypto.SHA256(d))
                    if sHash ~= entry.hash then
                        nModified = nModified + 1
                        tResults[entry.path] = "modified"
                    end
                end
            end
            tResults.files_modified = nModified
        end
    end
    
    local bClean = not tResults.kernel_modified and
                   (tResults.files_modified or 0) == 0
    
    return bClean, tResults
end

return oAttest