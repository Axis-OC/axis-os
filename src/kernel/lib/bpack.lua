--
-- /lib/bpack.lua
-- Binary pack/unpack for AXFS and RDB
--
local B = {}

function B.u16(n)
  return string.char(math.floor(n/256)%256, n%256)
end

function B.u32(n)
  return string.char(math.floor(n/16777216)%256, math.floor(n/65536)%256,
                     math.floor(n/256)%256, n%256)
end

function B.r16(s,o)
  o=o or 1; return s:byte(o)*256 + s:byte(o+1)
end

function B.r32(s,o)
  o=o or 1; return s:byte(o)*16777216 + s:byte(o+1)*65536 + s:byte(o+2)*256 + s:byte(o+3)
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

return B