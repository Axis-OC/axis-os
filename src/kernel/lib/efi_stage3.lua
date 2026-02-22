-- AxisOS EFI Stage 3 Bootloader v2.0
-- Loaded from AXEFI partition by Stage 1 EEPROM.
-- Verifies machine binding + kernel HMAC-SHA256 + remote attestation.
-- All bit32 calls strictly 2-argument. rrotate synthesized.

local C = component
local I = C.invoke
local D = _efi_drive
local ss = _efi_ss

local gpu, scr
for a in C.list("gpu") do gpu=a break end
for a in C.list("screen") do scr=a break end
if gpu and scr then pcall(I, gpu, "bind", scr) end
local cy = 4
local function p(t,c)
  if gpu then I(gpu,"setForeground",c or 0xFFFFFF); I(gpu,"set",1,cy,t); cy=cy+1 end
end
local function die(m)
  p("PANIC: "..m, 0xFF0000)
  computer.beep(200,1)
  while true do computer.pullSignal(1) end
end

local function rs(n) return I(D,"readSector",n+1) end
local function r16(s,o) return s:byte(o)*256+s:byte(o+1) end
local function r32(s,o)
  return s:byte(o)*0x1000000+s:byte(o+1)*0x10000
        +s:byte(o+2)*0x100+s:byte(o+3)
end

-- =========================================================
-- SHA-256 + HMAC-SHA256 (strictly 2-arg bxor, synthesized rrotate)
-- =========================================================
local sha256, hmac256
do
  local band  = bit32.band
  local bnot  = bit32.bnot
  local bxor2 = bit32.bxor   -- exactly 2 arguments
  local rsh   = bit32.rshift
  local lsh   = bit32.lshift
  local bor   = bit32.bor

  if not bor then
    bor = function(a,b) return bnot(band(bnot(a),bnot(b))) end
  end
  if not lsh then
    lsh = function(a,n) return (a * (2^n)) % 0x100000000 end
  end
  if not bnot then
    bnot = function(a) return bxor2(a, 0xFFFFFFFF) end
  end

  local M = 0x100000000

  -- Synthesize rrotate: (x >>> n) = (x >> n) | (x << (32-n))
  local function rrot(x, n)
    n = n % 32
    if n == 0 then return x end
    return bor(rsh(x, n), lsh(x, 32 - n))
  end

  -- 3-arg xor via nested 2-arg
  local function xor3(a, b, c)
    return bxor2(bxor2(a, b), c)
  end

  local K={
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
  local IV={
    0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
    0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19,
  }
  local function u32(n)
    return string.char(band(rsh(n,24),0xFF),band(rsh(n,16),0xFF),
                       band(rsh(n,8),0xFF),band(n,0xFF))
  end

  sha256 = function(msg)
    msg=tostring(msg); local len=#msg
    msg=msg.."\128"
    msg=msg..string.rep("\0",(56-#msg%64)%64)
    local bl=len*8
    msg=msg..u32(math.floor(bl/M))..u32(bl%M)
    local h1,h2,h3,h4,h5,h6,h7,h8 =
      IV[1],IV[2],IV[3],IV[4],IV[5],IV[6],IV[7],IV[8]
    for blk=1,#msg,64 do
      local W={}
      for j=1,16 do
        local o=blk+(j-1)*4
        W[j]=msg:byte(o)*0x1000000+msg:byte(o+1)*0x10000
            +msg:byte(o+2)*0x100+msg:byte(o+3)
      end
      for j=17,64 do
        local v=W[j-15]; local v2=W[j-2]
        local s0 = xor3(rrot(v,7), rrot(v,18), rsh(v,3))
        local s1 = xor3(rrot(v2,17), rrot(v2,19), rsh(v2,10))
        W[j] = (W[j-16] + s0 + W[j-7] + s1) % M
      end
      local a,b,c,d,e,f,gv,h = h1,h2,h3,h4,h5,h6,h7,h8
      for j=1,64 do
        local S1  = xor3(rrot(e,6), rrot(e,11), rrot(e,25))
        local ch  = bxor2(band(e,f), band(bnot(e),gv))
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
    if #key>64 then key=sha256(key) end
    key=key..string.rep("\0",64-#key)
    local ip,op={},{}
    for i=1,64 do
      local kb=key:byte(i)
      ip[i]=string.char(bxor2(kb,0x36))
      op[i]=string.char(bxor2(kb,0x5C))
    end
    return sha256(table.concat(op)..sha256(table.concat(ip)..msg))
  end
end

local function constEq(a,b)
  if #a~=#b then return false end
  local d=0
  for i=1,#a do d=bit32.bxor(d,bit32.bxor(a:byte(i),b:byte(i))) end
  return d==0
end

local function hex(s)
  local h={}; for i=1,#s do h[i]=string.format("%02x",s:byte(i)) end
  return table.concat(h)
end

-- =========================================================
-- READ EFI KEY BLOCK
-- =========================================================
p("Reading EFI key block...")
local kb = rs(_efi_off + 1)
if not kb or kb:sub(1,4)~="AKEY" then die("Invalid key block") end
local kbCrcStored = r32(kb, 103)
if kbCrcStored ~= 0 then
  -- Reuse our CRC32 from the EEPROM environment (passed in bit32)
  local ct2={}
  for i=0,255 do local c=i for _=1,8 do if c%2==1 then
    c=bit32.bxor(bit32.rshift(c,1),0xEDB88320) else c=bit32.rshift(c,1) end
  end ct2[i]=c end
  local function crc32(s) local c=0xFFFFFFFF for i=1,#s do
    c=bit32.bxor(bit32.rshift(c,8),ct2[bit32.band(bit32.bxor(c,s:byte(i)),0xFF)])
  end return bit32.bxor(c,0xFFFFFFFF) end
  if crc32(kb:sub(1,102)) ~= kbCrcStored then die("Key block CRC fail") end
end
local hmacKey = kb:sub(7, 38)
local kernSig = kb:sub(39, 70)
-- Extended key block fields (site-linked attestation)
local siteToken = kb:sub(107, 170)   -- 64 bytes: site attestation token
local pgpFpStored = kb:sub(171, 202) -- 32 bytes: PGP fingerprint
p("HMAC key loaded", 0xAAAAAA)

-- =========================================================
-- MACHINE BINDING VERIFICATION
-- =========================================================
if _efi_sb == 1 then
  p("Verifying machine binding...", 0xFFFF00)
  local eh = rs(_efi_off)
  local storedBinding = eh:sub(21, 52)
  local actualBinding = sha256(computer.address())
  if not constEq(storedBinding, actualBinding) then
    die("BINDING FAIL: wrong machine")
  end
  p("Machine binding: VALID", 0x00FF00)
end

-- =========================================================
-- REMOTE ATTESTATION (if internet card available)
-- =========================================================
local bRemoteOk = false
local sSessionToken = nil

if _efi_sb == 1 then
  local inet = nil
  for a in C.list("internet") do inet = a; break end

  if inet then
    p("Remote attestation...", 0xFFFF00)

    local function httpPost(sUrl, sBody)
      local h = I(inet, "request", sUrl, sBody, {["Content-Type"]="application/json"})
      if not h then return nil end
      -- Wait for connect
      local nDL = computer.uptime() + 10
      while computer.uptime() < nDL do
        local bOk, r1 = pcall(h.finishConnect)
        if bOk and r1 == true then break end
        if bOk and r1 == nil then return nil end
        computer.pullSignal(0.05)
      end
      local tC = {}
      local nRL = computer.uptime() + 5
      while computer.uptime() < nRL do
        local bOk, sD = pcall(h.read)
        if bOk and sD then tC[#tC+1] = sD
        elseif bOk and not sD then break end
        computer.pullSignal(0.01)
      end
      pcall(h.close)
      return table.concat(tC)
    end

    -- Step 1: Get challenge
    local actualBinding = hex(sha256(computer.address()))
    local sChResp = httpPost(
      "https://pki.axis-os.ru/api/machine_attest.php",
      '{"action":"challenge","machine_binding":"'..actualBinding..'"}'
    )

    if sChResp then
      local nonce = sChResp:match('"nonce"%s*:%s*"([^"]+)"')
      local chId  = sChResp:match('"challenge_id"%s*:%s*"([^"]+)"')

      if nonce and chId then
        -- Step 2: Sign the nonce with our HMAC key
        local nonceSignature = hex(hmac256(hmacKey, nonce))
        local sPgpFp = hex(pgpFpStored):gsub("00","")

        local sAttResp = httpPost(
          "https://pki.axis-os.ru/api/machine_attest.php",
          '{"action":"attest",'..
          '"challenge_id":"'..chId..'",'..
          '"nonce":"'..nonce..'",'..
          '"machine_binding":"'..actualBinding..'",'..
          '"nonce_hmac":"'..nonceSignature..'",'..
          '"pgp_fingerprint":"'..sPgpFp..'"}'
        )

        if sAttResp then
          local sStatus = sAttResp:match('"status"%s*:%s*"([^"]+)"')
          sSessionToken = sAttResp:match('"session_token"%s*:%s*"([^"]+)"')

          if sStatus == "attested" then
            bRemoteOk = true
            p("Remote attestation: PASSED", 0x00FF00)
          else
            local sReason = sAttResp:match('"reason"%s*:%s*"([^"]+)"') or "unknown"
            p("Attestation: "..sReason, 0xFF5555)
          end
        else
          p("Attestation: network error", 0xFFAA00)
        end
      end
    else
      p("Attestation: server unreachable", 0xFFAA00)
    end

    if not bRemoteOk and _efi_sb == 1 then
      -- Check if offline boot is allowed (key block byte 203)
      local bAllowOffline = (kb:byte(203) or 0) == 1
      if bAllowOffline then
        p("Offline boot allowed by policy", 0xFFAA00)
      else
        die("Remote attestation REQUIRED but failed")
      end
    end
  else
    p("No internet card (offline mode)", 0xFFAA00)
  end
end

-- =========================================================
-- FIND MAIN AXFS PARTITION
-- =========================================================
local rdb = _rdb
local tParts = _rdb_parts
local nParts = _rdb_nparts

local axOff, axSz
if tParts then
  for i=0,nParts-1 do
    local pt = tParts[i]
    if pt then
      local sType = pt.type:gsub("%s+","")
      if sType=="AXFS" or sType=="DH0" or pt.fsType==0x41584632 then
        axOff=pt.off; axSz=pt.sz; break
      end
    end
  end
end
if not axOff then die("No AXFS partition") end
p("AXFS @ sector "..axOff, 0xAAAAAA)

-- =========================================================
-- MINIMAL AXFS v2 READER
-- =========================================================
local function axRs(n) return rs(axOff + n) end
local sb = axRs(0)
if not sb or sb:sub(1,4)~="AXF2" then die("Bad AXFS superblock") end
local axSS = r16(sb, 6)
local nDS  = r16(sb, 20)
local nIT  = r16(sb, 22)
local ips  = math.floor(axSS / 80)
local dpb  = math.floor(axSS / 32)

local function readInode(n)
  local sec = nIT + math.floor(n / ips)
  local off = (n % ips) * 80
  local sd = axRs(sec); if not sd then return nil end
  local o = off + 1
  local fl = sd:byte(o+22); local ne = sd:byte(o+23)
  local t = {iType=r16(sd,o),size=r32(sd,o+8),flags=fl,nExtents=ne,
    extents={},indirect=r16(sd,o+76),inlineData=nil}
  if fl%2==1 then t.inlineData=sd:sub(o+24,o+24+math.min(t.size,52)-1)
  else for i=1,math.min(ne,13) do local eo=o+24+(i-1)*4
    t.extents[i]={r16(sd,eo),r16(sd,eo+2)} end end
  return t
end
local function readBlk(n) return axRs(nDS+n) end
local function iBlocks(t)
  if t.flags%2==1 then return {} end
  local r={}
  for i=1,math.min(t.nExtents,13) do local ext=t.extents[i]
    if ext and(ext[1]>0 or ext[2]>0)then
      for j=0,ext[2]-1 do r[#r+1]=ext[1]+j end end end
  if t.nExtents>13 and t.indirect>0 then local si=readBlk(t.indirect)
    if si then local ppb=math.floor(axSS/4)
      for i=1,ppb do local eS=r16(si,(i-1)*4+1); local eC=r16(si,(i-1)*4+3)
        if eC>0 then for j=0,eC-1 do r[#r+1]=eS+j end end end end end
  return r
end
local function dirLookup(di, nm)
  for _,bn in ipairs(iBlocks(di)) do local sd=readBlk(bn)
    if sd then for i=0,dpb-1 do local o=i*32+1; local ino=r16(sd,o)
      if ino>0 then local nl=sd:byte(o+3)
        if sd:sub(o+4,o+3+nl)==nm then return ino end end end end end
end
local function resolve(path)
  local cur=1
  for seg in path:gmatch("[^/]+") do
    local t=readInode(cur); if not t or t.iType~=2 then return nil end
    cur=dirLookup(t,seg); if not cur then return nil end
  end; return cur
end
local function readFile(path)
  local n=resolve(path); if not n then return nil end
  local t=readInode(n); if not t or t.iType~=1 then return nil end
  if t.flags%2==1 and t.inlineData then return t.inlineData:sub(1,t.size) end
  local ch={}; local rem=t.size
  for _,bn in ipairs(iBlocks(t)) do local sd=readBlk(bn)
    if sd then ch[#ch+1]=sd:sub(1,math.min(rem,axSS)); rem=rem-axSS end
    if rem<=0 then break end end
  return table.concat(ch)
end

-- =========================================================
-- BIOS SETUP (Stage 2) — if DEL was pressed
-- =========================================================
if _efi_setup_requested then
  p("Loading /boot/setup.lua...", 0xFFFF00)
  local sSetup = readFile("/boot/setup.lua")
  if sSetup then
    local setupEnv = {
      component=C, computer=computer, unicode=unicode,
      string=string, math=math, table=table, bit32=bit32,
      pairs=pairs, ipairs=ipairs, type=type,
      tostring=tostring, tonumber=tonumber,
      pcall=pcall, error=error, load=load,
      setmetatable=setmetatable, select=select,
    }
    setupEnv._G = setupEnv
    local fn2, e2 = load(sSetup, "@setup", "t", setupEnv)
    if fn2 then pcall(fn2)
    else p("Setup error: "..tostring(e2), 0xFF5555) end
  else
    p("/boot/setup.lua not found", 0xFF5555)
    computer.pullSignal(2)
  end
end

-- =========================================================
-- LOAD & VERIFY KERNEL
-- =========================================================
p("Loading /kernel.lua...")
local kern = readFile("/kernel.lua")
if not kern then die("Cannot read /kernel.lua") end
p("Kernel: "..#kern.." bytes", 0xAAAAAA)

if _efi_sb == 1 then
  p("Computing HMAC-SHA256...", 0xFFFF00)
  local actualSig = hmac256(hmacKey, kern)
  local bSigned = false
  for i=1,32 do if kernSig:byte(i)~=0 then bSigned=true break end end
  if not bSigned then die("Kernel NOT SIGNED") end
  if not constEq(kernSig, actualSig) then
    p("Expected: "..hex(kernSig):sub(1,16).."...", 0xFF6666)
    p("Got:      "..hex(actualSig):sub(1,16).."...", 0xFF6666)
    die("KERNEL SIGNATURE INVALID")
  end
  p("Kernel signature: VALID", 0x00FF00)
else
  p("SecureBoot OFF", 0xFFAA00)
end

-- =========================================================
-- BOOT KERNEL
-- =========================================================
p("Booting AxisOS kernel...", 0x00FF00)
computer.pullSignal(0.2)

local ke = {
  boot_fs_type     = "axfs",
  boot_drive_addr  = D,
  boot_part_offset = axOff,
  boot_part_size   = axSz,
  _sb_enabled      = (_efi_sb == 1),
  _sb_hmac_key     = (_efi_sb == 1) and hmacKey or nil,
  _sb_efi_offset   = _efi_off,
  _sb_efi_size     = _efi_sz,
  _sb_remote_ok    = bRemoteOk,
  _sb_session_token= sSessionToken,
  component=C, computer=computer, bit32=bit32,
  math=math, string=string, table=table, os=os,
  pairs=pairs, ipairs=ipairs, type=type,
  tostring=tostring, tonumber=tonumber,
  pcall=pcall, xpcall=xpcall, error=error,
  load=load, select=select, next=next,
  rawset=rawset, rawget=rawget,
  rawequal=rawequal, rawlen=rawlen,
  setmetatable=setmetatable, getmetatable=getmetatable,
  coroutine=coroutine, debug=debug,
  unpack=unpack or table.unpack,
}
setmetatable(ke, {__index = _G})
ke._G = ke; ke._ENV = ke

local fn3, err3 = load(kern, "=kernel", "t", ke)
if not fn3 then die("Kernel load: "..tostring(err3)) end
fn3()