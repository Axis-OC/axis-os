--
-- /lib/enclave.lua
-- User-space EXSi Enclave API v2
--

local oEnc = {}

-- v1 API (unchanged)
function oEnc.create(sCode, tOpts)
    return syscall("exsi_create", sCode, tOpts)
end

function oEnc.call(nHandle, sMethod, ...)
    return syscall("exsi_call", nHandle, sMethod, ...)
end

function oEnc.destroy(nHandle)
    return syscall("exsi_destroy", nHandle)
end

function oEnc.list()
    return syscall("exsi_list")
end

function oEnc.stats()
    return syscall("exsi_stats")
end

-- v2: Signed attestation with nonce
function oEnc.attest(nHandle, sUserData)
    return syscall("exsi_attest", nHandle, sUserData or "")
end

-- v2: Create with MRSIGNER (for version-resilient sealing)
function oEnc.createSigned(sCode, sMrSigner, nVersion, tThrottle)
    return oEnc.create(sCode, {
        sMrSigner = sMrSigner,
        nIsvSvn   = nVersion or 1,
        tThrottle = tThrottle,
    })
end

-- v2: Secure channel between two enclaves
function oEnc.openChannel(nHandleA, nHandleB)
    return syscall("exsi_channel_open", nHandleA, nHandleB)
end

function oEnc.channelSend(nChannelId, nSrcHandle, sData)
    return syscall("exsi_channel_send", nChannelId, nSrcHandle, sData)
end

function oEnc.closeChannel(nChannelId)
    return syscall("exsi_channel_close", nChannelId)
end

-- v2: Convenience — verify a Quote's signature
function oEnc.verifyQuote(tQuote, sExpectedMrEnclave, sExpectedUserData)
    if not tQuote then return false, "no quote" end
    if sExpectedMrEnclave and tQuote.sMrEnclave ~= sExpectedMrEnclave then
        return false, "MRENCLAVE mismatch"
    end
    if sExpectedUserData and tQuote.sUserData ~= sExpectedUserData then
        return false, "UserData/Nonce mismatch (replay?)"
    end
    if tQuote.sSignatureType == "NONE" then
        return false, "Quote is unsigned"
    end
    return true, tQuote.sSignatureType
end

return oEnc