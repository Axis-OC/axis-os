--
-- /lib/errcheck.lua
-- v3: Added quarantine, ring escalation, and HVCI error codes.
--

local g_tErrorCodes = {
  -- Success Codes
  STATUS_SUCCESS = 0,
  STATUS_PENDING = 1,

  -- Error Codes (300+)
  STATUS_UNSUCCESSFUL = 300,
  STATUS_NOT_IMPLEMENTED = 301,
  
  -- Driver-specific errors
  STATUS_INVALID_DRIVER_OBJECT = 400,
  STATUS_INVALID_DRIVER_ENTRY = 401,
  STATUS_INVALID_DRIVER_INFO = 402,
  STATUS_DRIVER_VALIDATION_FAILED = 403,
  STATUS_DRIVER_INIT_FAILED = 404,
  STATUS_NO_SUCH_DEVICE = 405,
  STATUS_DEVICE_ALREADY_EXISTS = 406,
  STATUS_INVALID_DRIVER_TYPE = 407,
  STATUS_DRIVER_UNLOAD_FAILED = 408,
  STATUS_DEVICE_NOT_READY = 409,

  -- Quarantine errors (420+)
  STATUS_DRIVER_QUARANTINED = 420,
  STATUS_DRIVER_FAULT_LIMIT = 421,
  STATUS_QUARANTINE_ENFORCED = 422,
  
  -- Access and Security errors
  STATUS_ACCESS_DENIED = 500,
  STATUS_PRIVILEGE_NOT_HELD = 501,
  STATUS_SYNAPSE_TOKEN_MISMATCH = 502,
  STATUS_SYNAPSE_TOKEN_EXPIRED = 503,

  -- Ring escalation errors (520+)
  STATUS_RING_ESCALATION_DETECTED = 520,
  STATUS_RING_ESCALATION_NIL_METHOD = 521,
  STATUS_RING_ESCALATION_TYPE_MISMATCH = 522,
  STATUS_RING_ESCALATION_METAMETHOD = 523,
  STATUS_RING_ESCALATION_SANDBOX_BREACH = 524,

  -- HVCI errors (540+)
  STATUS_HVCI_BLOCKED = 540,
  STATUS_HVCI_CAPABILITY_DENIED = 541,
  STATUS_HVCI_HASH_MISMATCH = 542,
  STATUS_HVCI_RUNTIME_VIOLATION = 543,
  STATUS_HVCI_UNSIGNED_CODE = 544,
  STATUS_HVCI_POLICY_VIOLATION = 545,

  -- VFS/IO errors
  STATUS_INVALID_HANDLE = 600,
  STATUS_INVALID_PARAMETER = 601,
  STATUS_END_OF_FILE = 602,
  STATUS_NO_SUCH_FILE = 603,
  STATUS_DEVICE_BUSY = 604,

  -- Object Manager errors
  STATUS_HANDLE_NOT_FOUND = 700,
  STATUS_HANDLE_TABLE_FULL = 701,
  STATUS_HANDLE_ALIAS_INVALID = 702,
}

local g_tErrorStrings = {
  [0] = "STATUS_SUCCESS: The operation completed successfully.",
  [1] = "STATUS_PENDING: The operation is in progress.",
  [300] = "STATUS_UNSUCCESSFUL: The operation failed.",
  [301] = "STATUS_NOT_IMPLEMENTED: Not implemented.",
  [400] = "STATUS_INVALID_DRIVER_OBJECT: Driver object is malformed.",
  [401] = "STATUS_INVALID_DRIVER_ENTRY: No valid DriverEntry.",
  [402] = "STATUS_INVALID_DRIVER_INFO: g_tDriverInfo missing or malformed.",
  [403] = "STATUS_DRIVER_VALIDATION_FAILED: Driver validation failed.",
  [404] = "STATUS_DRIVER_INIT_FAILED: DriverEntry returned error.",
  [405] = "STATUS_NO_SUCH_DEVICE: Device does not exist.",
  [406] = "STATUS_DEVICE_ALREADY_EXISTS: Device already exists.",
  [407] = "STATUS_INVALID_DRIVER_TYPE: Invalid driver type.",
  [408] = "STATUS_DRIVER_UNLOAD_FAILED: Unload failed.",
  [409] = "STATUS_DEVICE_NOT_READY: Device not ready.",
  [420] = "STATUS_DRIVER_QUARANTINED: Driver is quarantined due to repeated faults.",
  [421] = "STATUS_DRIVER_FAULT_LIMIT: Driver exceeded fault limit (3 errors in 60s).",
  [422] = "STATUS_QUARANTINE_ENFORCED: Quarantined driver blocked from loading. Clear via BIOS Setup.",
  [500] = "STATUS_ACCESS_DENIED: Permission denied.",
  [501] = "STATUS_PRIVILEGE_NOT_HELD: Higher ring required.",
  [502] = "STATUS_SYNAPSE_TOKEN_MISMATCH: sMLTR token mismatch.",
  [503] = "STATUS_SYNAPSE_TOKEN_EXPIRED: Token expired.",
  [520] = "STATUS_RING_ESCALATION_DETECTED: Ring privilege escalation attempt detected.",
  [521] = "STATUS_RING_ESCALATION_NIL_METHOD: Nil method call — possible metamethod exploitation.",
  [522] = "STATUS_RING_ESCALATION_TYPE_MISMATCH: Type mismatch in cross-ring IPC — possible injection.",
  [523] = "STATUS_RING_ESCALATION_METAMETHOD: Metamethod triggered in privileged context.",
  [524] = "STATUS_RING_ESCALATION_SANDBOX_BREACH: Sandbox boundary breach detected.",
  [540] = "STATUS_HVCI_BLOCKED: HVCI blocked driver load.",
  [541] = "STATUS_HVCI_CAPABILITY_DENIED: Driver lacks required capability.",
  [542] = "STATUS_HVCI_HASH_MISMATCH: Runtime code integrity hash mismatch.",
  [543] = "STATUS_HVCI_RUNTIME_VIOLATION: Runtime integrity violation detected.",
  [544] = "STATUS_HVCI_UNSIGNED_CODE: Unsigned code execution blocked by HVCI.",
  [545] = "STATUS_HVCI_POLICY_VIOLATION: HVCI policy violation.",
  [600] = "STATUS_INVALID_HANDLE: Invalid file handle.",
  [601] = "STATUS_INVALID_PARAMETER: Invalid parameter.",
  [602] = "STATUS_END_OF_FILE: End of file.",
  [603] = "STATUS_NO_SUCH_FILE: File not found.",
  [604] = "STATUS_DEVICE_BUSY: Device busy.",
  [700] = "STATUS_HANDLE_NOT_FOUND: Handle not found.",
  [701] = "STATUS_HANDLE_TABLE_FULL: Handle table full.",
  [702] = "STATUS_HANDLE_ALIAS_INVALID: Invalid handle alias.",
}

local oErrCheck = {}
for sName, nCode in pairs(g_tErrorCodes) do
  oErrCheck[sName] = nCode
end

function oErrCheck.fGetErrorString(nStatusCode)
  return g_tErrorStrings[nStatusCode] or "Unknown error: " .. tostring(nStatusCode)
end

return oErrCheck