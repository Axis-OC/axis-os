--
-- /lib/enclave.lua
-- User-space EXSi Enclave API
--
-- Provides Ring 3 access to EXSi enclaves through kernel syscalls.
-- No separate driver needed — syscalls are more efficient than IRP dispatch.
--
-- Usage:
--   local enc = require("enclave")
--
--   -- Create an enclave from source code
--   local h, mrHash = enc.create([=[
--       local secret = nil
--       return function(method, ...)
--           if method == "store" then
--               secret = select(1, ...)
--               return true
--           elseif method == "retrieve" then
--               return secret ~= nil and "has_secret" or "empty"
--           elseif method == "seal" then
--               return seal(secret or "")
--           elseif method == "unseal" then
--               secret = unseal(select(1, ...))
--               return secret ~= nil
--           end
--       end
--   ]=])
--
--   -- Call enclave methods
--   enc.call(h, "store", "my_private_key_data")
--   print(enc.call(h, "retrieve"))  -- "has_secret"
--
--   -- Attestation: verify enclave identity
--   local proof = enc.attest(h)
--   print(proof.sMrEnclave)  -- SHA-256 hex of source code
--
--   -- Seal data to disk (only this enclave on this machine can unseal)
--   local blob = enc.call(h, "seal")
--   -- ... write blob to file ...
--   -- ... later, recreate same enclave, unseal: ...
--   enc.call(h, "unseal", blob)
--
--   -- List all enclaves
--   local list = enc.list()
--
--   -- Cleanup
--   enc.destroy(h)
--

local oEnc = {}

-- Create a new enclave from source code.
-- Returns: handle (number), MRENCLAVE hex string, or nil + error.
function oEnc.create(sCode)
    return syscall("exsi_create", sCode)
end

-- Call an enclave method.
-- Returns: whatever the enclave function returns, or nil + error.
function oEnc.call(nHandle, sMethod, ...)
    return syscall("exsi_call", nHandle, sMethod, ...)
end

-- Attest an enclave: get its MRENCLAVE hash and metadata.
-- Returns: table {sMrEnclave, nOwnerPid, nCreatedAt, nCallCount, nCodeSize}
function oEnc.attest(nHandle)
    return syscall("exsi_attest", nHandle)
end

-- Destroy an enclave (must be owner or Ring 0-1).
function oEnc.destroy(nHandle)
    return syscall("exsi_destroy", nHandle)
end

-- List all active enclaves (public metadata only).
function oEnc.list()
    return syscall("exsi_list")
end

-- Get EXSi subsystem statistics.
function oEnc.stats()
    return syscall("exsi_stats")
end

return oEnc