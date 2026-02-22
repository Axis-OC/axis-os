--
-- /lib/bpack.lua
-- Binary pack/unpack for AXFS v2 and Amiga RDB
-- v2: CRC32, CRC16, u8, i32, u48 support
--
local B = {}

-- =============================================
-- PACK / UNPACK PRIMITIVES
-- =============================================

function B.u8(n)   return string.char(math.floor(n) % 256) end
function B.r8(s,o) o=o or 1; return s:byte(o) end

function B.u16(n)
  n = math.floor(n)
  return string.char(math.floor(n/256)%256, n%256)
end
function B.r16(s,o)
  o=o or 1; return s:byte(o)*256 + s:byte(o+1)
end

function B.u32(n)
  n = math.floor(n)
  return string.char(
    math.floor(n/16777216)%256, math.floor(n/65536)%256,
    math.floor(n/256)%256, n%256)
end
function B.r32(s,o)
  o=o or 1
  return s:byte(o)*16777216 + s:byte(o+1)*65536
       + s:byte(o+2)*256 + s:byte(o+3)
end

-- Signed 32-bit (two's complement)
function B.i32(n)
  n = math.floor(n)
  if n < 0 then n = n + 4294967296 end
  return B.u32(n)
end
function B.ri32(s,o)
  local u = B.r32(s,o)
  if u >= 2147483648 then return u - 4294967296 end
  return u
end

-- 48-bit (6 bytes) for extended addressing
function B.u48(n)
  n = math.floor(n)
  return string.char(
    math.floor(n/1099511627776)%256,
    math.floor(n/4294967296)%256,
    math.floor(n/16777216)%256,
    math.floor(n/65536)%256,
    math.floor(n/256)%256, n%256)
end
function B.r48(s,o)
  o=o or 1
  return s:byte(o)*1099511627776 + s:byte(o+1)*4294967296
       + s:byte(o+2)*16777216 + s:byte(o+3)*65536
       + s:byte(o+4)*256 + s:byte(o+5)
end

function B.str(s,n)
  if #s>=n then return s:sub(1,n) end
  return s..string.rep("\0",n-#s)
end
function B.rstr(s,o,n)
  local r=s:sub(o,o+n-1); local z=r:find("\0",1,true)
  return z and r:sub(1,z-1) or r
end
function B.pad(s,n)
  if #s>=n then return s:sub(1,n) end
  return s..string.rep("\0",n-#s)
end

-- =============================================
-- CRC32 (IEEE 802.3 polynomial 0xEDB88320)
-- =============================================

local g_tCrc32 = nil

local function _initCrc32()
  if g_tCrc32 then return end
  g_tCrc32 = {}
  for i = 0, 255 do
    local c = i
    for _ = 0, 7 do
      if c % 2 == 1 then
        c = bit32.bxor(bit32.rshift(c, 1), 0xEDB88320)
      else
        c = bit32.rshift(c, 1)
      end
    end
    g_tCrc32[i] = c
  end
end

function B.crc32(sData)
  _initCrc32()
  local crc = 0xFFFFFFFF
  for i = 1, #sData do
    local idx = bit32.band(bit32.bxor(crc, sData:byte(i)), 0xFF)
    crc = bit32.bxor(bit32.rshift(crc, 8), g_tCrc32[idx])
  end
  return bit32.bxor(crc, 0xFFFFFFFF)
end

function B.crc32_bytes(sData)
  return B.u32(B.crc32(sData))
end

function B.crc32_verify(sData, nExpected)
  return B.crc32(sData) == nExpected
end

-- =============================================
-- CRC16 (CCITT polynomial 0x8408)
-- =============================================

function B.crc16(sData)
  local crc = 0xFFFF
  for i = 1, #sData do
    crc = bit32.bxor(crc, sData:byte(i))
    for _ = 0, 7 do
      if crc % 2 == 1 then
        crc = bit32.bxor(bit32.rshift(crc, 1), 0x8408)
      else
        crc = bit32.rshift(crc, 1)
      end
    end
  end
  return bit32.bxor(crc, 0xFFFF)
end

-- =============================================
-- AMIGA-STYLE BLOCK CHECKSUM
-- Sum of all u32 longs in the block must equal 0.
-- Returns the checksum value to store at the checksum offset.
-- =============================================

function B.amiga_checksum(sBlock, nChecksumOffset)
  -- nChecksumOffset is 1-based byte offset of the u32 checksum field
  local nSum = 0
  for i = 1, #sBlock, 4 do
    if i ~= nChecksumOffset then
      local v = B.r32(sBlock, i)
      nSum = (nSum + v) % 4294967296
    end
  end
  -- Checksum = (0 - sum) mod 2^32
  return (4294967296 - nSum) % 4294967296
end

function B.amiga_verify(sBlock, nChecksumOffset)
  local nSum = 0
  for i = 1, #sBlock, 4 do
    nSum = (nSum + B.r32(sBlock, i)) % 4294967296
  end
  return nSum == 0
end

return B