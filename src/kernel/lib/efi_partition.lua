--
-- /lib/efi_partition.lua
-- AxisOS EFI Partition Manager — Third-Layer Boot Encryption
--
-- Handles:
--   • HMAC-keystream XOR encryption/decryption
--   • Key derivation from SecureBoot private key + machine binding
--   • EFI header/key-block pack/unpack
--   • Machine binding computation
--   • Content integrity verification
--
-- The EFI partition encrypts itself with a key derived from:
--   decryption_key = HMAC-SHA256(secureboot_key, machine_binding)
-- This means the partition can ONLY be decrypted on the correct
-- machine with the correct SecureBoot key.
--
-- Portability: SHA-256 uses only band/bor/bxor/bnot/rshift/lshift.
-- bit32.rrotate is synthesized if missing (Lua 5.3 kernel).
-- All bxor calls are 2-argument (kernel synthesized bit32 limit).
--

local B = require("bpack")
local EFI = {}

-- =============================================
-- CONSTANTS
-- =============================================

EFI.HEADER_MAGIC = "AEFI"
EFI.KEY_MAGIC    = "AKEY"
EFI.VERSION      = 2

EFI.ENC_NONE     = 0
EFI.ENC_XOR_HMAC = 1
EFI.ENC_DATA_CARD = 2

-- =============================================
-- PORTABLE SHA-256 + HMAC-SHA256
-- Uses ONLY: band, bor, bxor(2-arg), bnot, rshift, lshift.
-- rrotate is synthesized from rshift+lshift+bor.
-- All xor calls are strictly 2-argument.
-- =============================================

local sha256, hmac256
do
  local band  = bit32.band
  local bnot  = bit32.bnot
  local rsh   = bit32.rshift
  local lsh   = bit32.lshift
  local bor   = bit32.bor
  local bxor  = bit32.bxor  -- strictly 2-argument
  local M = 0x100000000

  -- Synthesize rrotate if missing (Lua 5.3 kernel path)
  local rrot = bit32.rrotate
  if not rrot then
    rrot = function(x, n)
      n = n % 32
      if n == 0 then return x end
      return bor(rsh(x, n), lsh(x, 32 - n))
    end
  end

  -- 3-argument xor helper (kernel bxor only takes 2)
  local function xor3(a, b, c)
    return bxor(bxor(a, b), c)
  end

  local K = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,
    0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,
    0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,
    0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,
    0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,
    0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,
    0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,
    0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,
    0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
  }
  local IV = {
    0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
    0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19,
  }
  local function u32(n)
    return string.char(band(rsh(n,24),0xFF), band(rsh(n,16),0xFF),
                       band(rsh(n,8),0xFF), band(n,0xFF))
  end

  sha256 = function(msg)
    msg = tostring(msg); local len = #msg
    msg = msg .. "\128"
    msg = msg .. string.rep("\0", (56 - #msg % 64) % 64)
    local bl = len * 8
    msg = msg .. u32(math.floor(bl / M)) .. u32(bl % M)
    local h1,h2,h3,h4,h5,h6,h7,h8 =
      IV[1],IV[2],IV[3],IV[4],IV[5],IV[6],IV[7],IV[8]
    for blk = 1, #msg, 64 do
      local W = {}
      for j = 1, 16 do
        local o = blk + (j-1)*4
        W[j] = msg:byte(o)*0x1000000 + msg:byte(o+1)*0x10000
             + msg:byte(o+2)*0x100   + msg:byte(o+3)
      end
      for j = 17, 64 do
        local v = W[j-15]; local v2 = W[j-2]
        local s0 = xor3(rrot(v,7), rrot(v,18), rsh(v,3))
        local s1 = xor3(rrot(v2,17), rrot(v2,19), rsh(v2,10))
        W[j] = (W[j-16] + s0 + W[j-7] + s1) % M
      end
      local a,b,c,d,e,f,gv,h = h1,h2,h3,h4,h5,h6,h7,h8
      for j = 1, 64 do
        local S1  = xor3(rrot(e,6), rrot(e,11), rrot(e,25))
        local ch  = bxor(band(e,f), band(bnot(e),gv))
        local t1  = (h + S1 + ch + K[j] + W[j]) % M
        local S0  = xor3(rrot(a,2), rrot(a,13), rrot(a,22))
        local maj = xor3(band(a,b), band(a,c), band(b,c))
        local t2  = (S0 + maj) % M
        h=gv; gv=f; f=e; e=(d+t1)%M
        d=c; c=b; b=a; a=(t1+t2)%M
      end
      h1=(h1+a)%M; h2=(h2+b)%M; h3=(h3+c)%M; h4=(h4+d)%M
      h5=(h5+e)%M; h6=(h6+f)%M; h7=(h7+gv)%M; h8=(h8+h)%M
    end
    return u32(h1)..u32(h2)..u32(h3)..u32(h4)
        ..u32(h5)..u32(h6)..u32(h7)..u32(h8)
  end

  hmac256 = function(key, msg)
    if #key > 64 then key = sha256(key) end
    key = key .. string.rep("\0", 64 - #key)
    local ip, op = {}, {}
    for i = 1, 64 do
      local kb = key:byte(i)
      ip[i] = string.char(bxor(kb, 0x36))
      op[i] = string.char(bxor(kb, 0x5C))
    end
    return sha256(table.concat(op) .. sha256(table.concat(ip) .. msg))
  end
end

EFI.sha256 = sha256
EFI.hmac256 = hmac256

-- =============================================
-- UTILITY
-- =============================================

function EFI.hex(s)
  if not s then return "" end
  local t = {}
  for i = 1, #s do t[i] = string.format("%02x", s:byte(i)) end
  return table.concat(t)
end

function EFI.constEq(a, b)
  if #a ~= #b then return false end
  local d = 0
  for i = 1, #a do d = bit32.bxor(d, bit32.bxor(a:byte(i), b:byte(i))) end
  return d == 0
end

-- =============================================
-- MACHINE BINDING
-- =============================================

function EFI.computeBinding(fComponentList)
  if not fComponentList then
    return sha256(computer.address())
  end
  local tParts = {}
  for addr, ctype in fComponentList() do
    tParts[#tParts + 1] = ctype .. ":" .. addr
  end
  table.sort(tParts)
  return sha256(table.concat(tParts, "|"))
end

function EFI.computeBindingSimple(sComputerAddr)
  return sha256(sComputerAddr)
end

-- =============================================
-- KEY DERIVATION
-- decryption_key = HMAC-SHA256(secureboot_key, machine_binding)
-- =============================================

function EFI.deriveKey(sSecureBootKey, sMachineBinding)
  if not sSecureBootKey or #sSecureBootKey == 0 then
    return nil, "No SecureBoot key"
  end
  if not sMachineBinding or #sMachineBinding == 0 then
    return nil, "No machine binding"
  end
  return hmac256(sSecureBootKey, sMachineBinding)
end

-- =============================================
-- XOR-HMAC KEYSTREAM CIPHER
-- Counter-mode HMAC keystream, XOR with data.
-- Same operation for encrypt and decrypt.
-- =============================================

function EFI.xorCipher(sKey, sData)
  local nLen = #sData
  local tOut = {}
  local nBlockIdx = 0
  local nPos = 1

  while nPos <= nLen do
    local sCounter = B.u32(nBlockIdx) .. B.u32(nLen)
    local sKeyBlock = hmac256(sKey, sCounter)

    for i = 1, 32 do
      if nPos > nLen then break end
      local bData = sData:byte(nPos)
      local bKey  = sKeyBlock:byte(i)
      tOut[#tOut + 1] = string.char(bit32.bxor(bData, bKey))
      nPos = nPos + 1
    end

    nBlockIdx = nBlockIdx + 1
  end

  return table.concat(tOut)
end

-- =============================================
-- ENCRYPT / DECRYPT PARTITION CONTENT
-- =============================================

function EFI.encryptContent(sPlaintext, sSecureBootKey, sMachineBinding)
  local sKey, sErr = EFI.deriveKey(sSecureBootKey, sMachineBinding)
  if not sKey then return nil, sErr end

  local nPlaintextCrc = B.crc32(sPlaintext)
  local sEncrypted = EFI.xorCipher(sKey, sPlaintext)
  local nEncryptedCrc = B.crc32(sEncrypted)

  return sEncrypted, {
    plaintextCrc  = nPlaintextCrc,
    encryptedCrc  = nEncryptedCrc,
    plaintextLen  = #sPlaintext,
    encryptedLen  = #sEncrypted,
    contentHash   = sha256(sPlaintext),
    bindingHash   = sMachineBinding,
  }
end

function EFI.decryptContent(sEncrypted, sSecureBootKey, sMachineBinding, tExpected)
  local sKey, sErr = EFI.deriveKey(sSecureBootKey, sMachineBinding)
  if not sKey then return nil, sErr end

  if tExpected and tExpected.encryptedCrc then
    if B.crc32(sEncrypted) ~= tExpected.encryptedCrc then
      return nil, "Encrypted content CRC mismatch (data corrupted)"
    end
  end

  local sDecrypted = EFI.xorCipher(sKey, sEncrypted)

  if tExpected then
    if tExpected.plaintextCrc then
      if B.crc32(sDecrypted) ~= tExpected.plaintextCrc then
        return nil, "Decryption CRC mismatch (wrong key or binding)"
      end
    end
    if tExpected.contentHash then
      if not EFI.constEq(sha256(sDecrypted), tExpected.contentHash) then
        return nil, "Decryption hash mismatch (tampered content)"
      end
    end
  end

  return sDecrypted
end

-- =============================================
-- EFI HEADER PACK/UNPACK
-- =============================================

function EFI.packHeader(t, nSS)
  local s = EFI.HEADER_MAGIC
    .. B.u8(t.version or EFI.VERSION)
    .. B.u16(t.bootCodeSize or 0)
    .. B.u32(t.bootCodeCrc or 0)
    .. B.u16(t.keyBlockStart or 1)
    .. B.u16(t.keyBlockCount or 2)
    .. B.u16(t.bootCodeStart or 3)
    .. B.u16(t.bootCodeCount or 0)
    .. B.u8(t.secureBoot and 1 or 0)
    .. B.pad(t.machineBinding or "", 32)

  s = s .. B.u32(B.crc32(s))

  s = s .. B.u8(t.encryptMode or EFI.ENC_NONE)
    .. B.u16(t.encCodeSize or 0)
    .. B.u32(t.encCodeCrc or 0)
    .. B.pad("", 32)
    .. B.u8(t.bindingVerified and 1 or 0)

  return B.pad(s, nSS)
end

function EFI.unpackHeader(s)
  if not s or #s < 96 then return nil, "Too short" end
  if s:sub(1, 4) ~= EFI.HEADER_MAGIC then return nil, "Bad magic" end

  local nStoredCrc = B.r32(s, 53)
  if B.crc32(s:sub(1, 52)) ~= nStoredCrc then
    return nil, "Header CRC invalid"
  end

  return {
    version         = s:byte(5),
    bootCodeSize    = B.r16(s, 6),
    bootCodeCrc     = B.r32(s, 8),
    keyBlockStart   = B.r16(s, 12),
    keyBlockCount   = B.r16(s, 14),
    bootCodeStart   = B.r16(s, 16),
    bootCodeCount   = B.r16(s, 18),
    secureBoot      = s:byte(20) == 1,
    machineBinding  = s:sub(21, 52),
    encryptMode     = #s >= 57 and s:byte(57) or 0,
    encCodeSize     = #s >= 59 and B.r16(s, 58) or 0,
    encCodeCrc      = #s >= 63 and B.r32(s, 60) or 0,
    bindingVerified = #s >= 96 and s:byte(96) == 1 or false,
  }
end

-- =============================================
-- KEY BLOCK PACK/UNPACK
-- =============================================

function EFI.packKeyBlock(t, nSS)
  local s = EFI.KEY_MAGIC
    .. B.u8(t.keyType or 1)
    .. B.u8(t.keyLen or 32)
    .. B.pad(t.hmacKey or "", 32)
    .. B.pad(t.kernelSig or "", 32)
    .. B.pad(t.bootCodeSig or "", 32)
  s = s .. B.u32(B.crc32(s))
  -- Extended v2 fields
  s = s .. B.pad(t.encPartitionKey or "", 32)
  s = s .. B.pad(t.bindingProof or "", 32)
  s = s .. B.pad(t.siteToken or "", 64)        -- [107-170] derived key from server
  s = s .. B.pad(t.pgpFingerprint or "", 32)    -- [171-202] PGP fingerprint
  s = s .. B.u8(t.allowOffline and 1 or 0)      -- [203] offline policy
  s = s .. B.pad("", 3)                          -- [204-206] reserved
  return B.pad(s, nSS)
end

function EFI.unpackKeyBlock(s)
  if not s or #s < 106 then return nil, "Too short" end
  if s:sub(1, 4) ~= EFI.KEY_MAGIC then return nil, "Bad magic" end

  local nStoredCrc = B.r32(s, 103)
  if nStoredCrc ~= 0 and B.crc32(s:sub(1, 102)) ~= nStoredCrc then
    return nil, "Key block CRC invalid"
  end

  return {
    keyType         = s:byte(5),
    keyLen          = s:byte(6),
    hmacKey         = s:sub(7, 38),
    kernelSig       = s:sub(39, 70),
    bootCodeSig     = s:sub(71, 102),
    encPartitionKey = #s >= 138 and s:sub(107, 138) or "",
    bindingProof    = #s >= 170 and s:sub(139, 170) or "",
  }
end

-- =============================================
-- GENERATE FRESH HMAC KEY
-- =============================================

function EFI.generateHmacKey()
  local sSeed = ""
  pcall(function()
    sSeed = sSeed .. computer.address()
    sSeed = sSeed .. tostring(computer.uptime())
  end)
  for i = 1, 8 do
    sSeed = sSeed .. tostring(math.random(0, 0x7FFFFFFF))
  end
  return sha256(sha256(sSeed))
end

-- =============================================
-- FULL EFI PARTITION SETUP
-- =============================================

function EFI.setupPartition(tDisk, nPartOffset, nPartSize, tOpts)
  tOpts = tOpts or {}
  local ss = tDisk.sectorSize

  local sBootCode     = tOpts.bootCode or ""
  local bSecureBoot   = tOpts.secureBoot ~= false
  local sMachineAddr  = tOpts.machineAddr or ""
  local sCustomKey    = tOpts.hmacKey

  local sHmacKey = sCustomKey or EFI.generateHmacKey()
  local sBinding = sha256(sMachineAddr)
  local sKernelSig = string.rep("\0", 32)
  local sBootCodeSig = hmac256(sHmacKey, sBootCode)

  local sWriteCode = sBootCode
  local nEncMode = EFI.ENC_NONE
  local nEncSize, nEncCrc = 0, 0
  local sContentHash = sha256(sBootCode)
  local sEncPartKey = ""
  local sBindingProof = ""

  if bSecureBoot and #sBootCode > 0 then
    nEncMode = EFI.ENC_XOR_HMAC

    local sEncKey = EFI.deriveKey(sHmacKey, sBinding)
    if sEncKey then
      sWriteCode = EFI.xorCipher(sEncKey, sBootCode)
      nEncSize = #sWriteCode
      nEncCrc = B.crc32(sWriteCode)

      sEncPartKey = hmac256(sBinding, sHmacKey)
      sBindingProof = hmac256(sHmacKey, sBinding)
    end
  end

  local nKeyStart = 1
  local nKeyCount = 2
  local nBootStart = nKeyStart + nKeyCount
  local nBootCount = math.ceil(#sWriteCode / ss)

  if nBootStart + nBootCount > nPartSize then
    return nil, "Boot code too large for EFI partition"
  end

  tDisk.writeSector(nPartOffset, EFI.packHeader({
    version        = EFI.VERSION,
    bootCodeSize   = #sBootCode,
    bootCodeCrc    = B.crc32(sBootCode),
    keyBlockStart  = nKeyStart,
    keyBlockCount  = nKeyCount,
    bootCodeStart  = nBootStart,
    bootCodeCount  = nBootCount,
    secureBoot     = bSecureBoot,
    machineBinding = sBinding,
    encryptMode    = nEncMode,
    encCodeSize    = nEncSize,
    encCodeCrc     = nEncCrc,
  }, ss))

  tDisk.writeSector(nPartOffset + nKeyStart, EFI.packKeyBlock({
    keyType         = 1,
    keyLen          = 32,
    hmacKey         = sHmacKey,
    kernelSig       = sKernelSig,
    bootCodeSig     = sBootCodeSig,
    encPartitionKey = sEncPartKey,
    bindingProof    = sBindingProof,
  }, ss))

  tDisk.writeSector(nPartOffset + nKeyStart + 1, B.pad("", ss))

  for i = 0, nBootCount - 1 do
    local sChunk = sWriteCode:sub(i * ss + 1, (i + 1) * ss)
    tDisk.writeSector(nPartOffset + nBootStart + i, B.pad(sChunk, ss))
  end

  return true, {
    hmacKey        = sHmacKey,
    machineBinding = sBinding,
    contentHash    = sContentHash,
    encrypted      = bSecureBoot,
    encryptMode    = nEncMode,
    bootCodeSize   = #sBootCode,
    bootSectors    = nBootCount,
  }
end

-- =============================================
-- VERIFY + DECRYPT (for boot process)
-- =============================================

function EFI.loadAndDecrypt(tDisk, nPartOffset, sSecureBootKey, sMachineAddr)
  local ss = tDisk.sectorSize

  local sHdr = tDisk.readSector(nPartOffset)
  local tHdr, sHdrErr = EFI.unpackHeader(sHdr)
  if not tHdr then return nil, "EFI header: " .. (sHdrErr or "?") end

  local sCurrentBinding = sha256(sMachineAddr)
  if not EFI.constEq(tHdr.machineBinding, sCurrentBinding) then
    return nil, "BINDING FAIL: drive moved to different machine"
  end

  local sKb = tDisk.readSector(nPartOffset + tHdr.keyBlockStart)
  local tKb, sKbErr = EFI.unpackKeyBlock(sKb)
  if not tKb then return nil, "Key block: " .. (sKbErr or "?") end

  local tChunks = {}
  for i = 0, tHdr.bootCodeCount - 1 do
    local sd = tDisk.readSector(nPartOffset + tHdr.bootCodeStart + i)
    if sd then tChunks[#tChunks + 1] = sd end
  end
  local sRawCode = table.concat(tChunks)

  if tHdr.encryptMode == EFI.ENC_XOR_HMAC then
    if not sSecureBootKey then
      sSecureBootKey = tKb.hmacKey
    end

    local sEncKey = EFI.deriveKey(sSecureBootKey, sCurrentBinding)
    if not sEncKey then
      return nil, "Key derivation failed"
    end

    local sEncData = sRawCode:sub(1, tHdr.encCodeSize > 0 and tHdr.encCodeSize or #sRawCode)
    if tHdr.encCodeCrc ~= 0 then
      if B.crc32(sEncData) ~= tHdr.encCodeCrc then
        return nil, "Encrypted content CRC mismatch"
      end
    end

    sRawCode = EFI.xorCipher(sEncKey, sEncData)
  end

  local sBootCode = sRawCode:sub(1, tHdr.bootCodeSize)
  if B.crc32(sBootCode) ~= tHdr.bootCodeCrc then
    return nil, "Boot code CRC fail (wrong key or corrupted)"
  end

  return sBootCode, {
    header   = tHdr,
    keyBlock = tKb,
    binding  = sCurrentBinding,
  }
end

return EFI