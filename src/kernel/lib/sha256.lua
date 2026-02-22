--
-- /lib/sha256.lua
-- Pure Lua SHA-256 + HMAC-SHA256 (FIPS 180-4 / RFC 2104)
-- Requires: bit32 (OC Lua 5.2 native or kernel-synthesized)
-- Zero component calls. ~0.3ms per 512B block on OC.
--
local S = {}

local band  = bit32.band
local bnot  = bit32.bnot
local bxor  = bit32.bxor
local rrot  = bit32.rrotate
local rsh   = bit32.rshift
local MOD   = 0x100000000

-- Round constants: first 32 bits of fractional parts of
-- cube roots of first 64 primes (2..311)
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

-- Initial hash: first 32 bits of fractional parts of
-- square roots of first 8 primes (2..19)
local IV = {
  0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
  0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19,
}

local function u32(n)
  return string.char(
    band(rsh(n,24),0xFF), band(rsh(n,16),0xFF),
    band(rsh(n,8),0xFF),  band(n,0xFF))
end

--- Compute SHA-256 digest of a string.
-- @param msg  Input string (any length)
-- @return     32-byte binary digest string
function S.digest(msg)
  msg = tostring(msg)
  local len = #msg

  -- Padding: 1-bit, zeros, 64-bit BE length
  msg = msg .. "\128"
  msg = msg .. string.rep("\0", (56 - #msg % 64) % 64)
  local bl = len * 8
  msg = msg .. u32(math.floor(bl / MOD)) .. u32(bl % MOD)

  -- State
  local h1,h2,h3,h4 = IV[1],IV[2],IV[3],IV[4]
  local h5,h6,h7,h8 = IV[5],IV[6],IV[7],IV[8]

  -- Process 512-bit blocks
  for blk = 1, #msg, 64 do
    -- Message schedule W[1..64]
    local W = {}
    for j = 1, 16 do
      local o = blk + (j-1)*4
      W[j] = msg:byte(o)*0x1000000 + msg:byte(o+1)*0x10000
           + msg:byte(o+2)*0x100   + msg:byte(o+3)
    end
    for j = 17, 64 do
      local v15 = W[j-15]; local v2 = W[j-2]
      local s0 = bxor(rrot(v15,7), rrot(v15,18), rsh(v15,3))
      local s1 = bxor(rrot(v2,17), rrot(v2,19),  rsh(v2,10))
      W[j] = (W[j-16] + s0 + W[j-7] + s1) % MOD
    end

    -- Working variables
    local a,b,c,d,e,f,gv,h = h1,h2,h3,h4,h5,h6,h7,h8

    -- 64 compression rounds
    for j = 1, 64 do
      local S1  = bxor(rrot(e,6), rrot(e,11), rrot(e,25))
      local ch  = bxor(band(e,f), band(bnot(e),gv))
      local t1  = (h + S1 + ch + K[j] + W[j]) % MOD
      local S0  = bxor(rrot(a,2), rrot(a,13), rrot(a,22))
      local maj = bxor(band(a,b), band(a,c), band(b,c))
      local t2  = (S0 + maj) % MOD
      h=gv; gv=f; f=e; e=(d+t1)%MOD
      d=c; c=b; b=a; a=(t1+t2)%MOD
    end

    h1=(h1+a)%MOD; h2=(h2+b)%MOD; h3=(h3+c)%MOD; h4=(h4+d)%MOD
    h5=(h5+e)%MOD; h6=(h6+f)%MOD; h7=(h7+gv)%MOD; h8=(h8+h)%MOD
  end

  return u32(h1)..u32(h2)..u32(h3)..u32(h4)
      .. u32(h5)..u32(h6)..u32(h7)..u32(h8)
end

--- HMAC-SHA256 (RFC 2104).
-- @param key  Secret key (any length; >64 bytes auto-hashed)
-- @param msg  Message to authenticate
-- @return     32-byte binary MAC
function S.hmac(key, msg)
  if #key > 64 then key = S.digest(key) end
  key = key .. string.rep("\0", 64 - #key)
  local ip, op = {}, {}
  for i = 1, 64 do
    local kb = key:byte(i)
    ip[i] = string.char(bxor(kb, 0x36))
    op[i] = string.char(bxor(kb, 0x5C))
  end
  return S.digest(table.concat(op) .. S.digest(table.concat(ip) .. msg))
end

--- Binary digest → hex string.
function S.hex(s)
  local h = {}
  for i = 1, #s do h[i] = string.format("%02x", s:byte(i)) end
  return table.concat(h)
end

--- Hex string → binary.
function S.fromHex(h)
  local b = {}
  for i = 1, #h, 2 do b[#b+1] = string.char(tonumber(h:sub(i,i+1), 16)) end
  return table.concat(b)
end

--- Constant-time comparison (timing-attack safe).
function S.constEq(a, b)
  if #a ~= #b then return false end
  local d = 0
  for i = 1, #a do d = bxor(d, bxor(a:byte(i), b:byte(i))) end
  return d == 0
end

return S