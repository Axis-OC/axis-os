--
-- /lib/olr.lua
-- Owner Lock Region — Hardware-Bound Owner Identity (FRP equivalent)
--
-- Written once during first-user setup. Checked by init.lua at login.
-- Clearable only from an authenticated owner session or BIOS Setup.
--
-- RDB partition type: FS_AXOLR = 0x41584F4C ("AXOL")
-- Flags: PF_HIDDEN_FS | PF_SYSTEM
--
-- RAM cost: 0 persistent, ~512B peak (one sector buffer on stack)
--

local B = require("bpack")
local OLR = {}

OLR.MAGIC   = "AXOL"
OLR.VERSION = 1
OLR.FS_TYPE = 0x41584F4C  -- "AXOL"

OLR.STATUS_EMPTY   = 0
OLR.STATUS_LOCKED  = 1
OLR.STATUS_CLEARED = 2

-- =============================================
-- HASH HELPERS (reuse kernel's sha256 if loaded)
-- =============================================

local function fGetSha256()
    local bOk, oMod = pcall(require, "sha256")
    return bOk and oMod or nil
end

local function fHash(sData)
    local oS = fGetSha256()
    if oS then return oS.digest(sData) end
    -- Fallback: double-CRC expansion (weak but distinct)
    local c = B.crc32(sData)
    local t = {}
    for i = 0, 7 do
        c = B.crc32(B.u32(c) .. B.u32(i))
        t[i + 1] = B.u32(c)
    end
    return table.concat(t)
end

local function fHmac(sKey, sData)
    local oS = fGetSha256()
    if oS and oS.hmac then return oS.hmac(sKey, sData) end
    return fHash(sKey .. "|" .. sData)
end

local function fConstEq(a, b)
    if #a ~= #b then return false end
    local d = 0
    for i = 1, #a do d = bit32.bxor(d, bit32.bxor(a:byte(i), b:byte(i))) end
    return d == 0
end

-- =============================================
-- MACHINE BINDING — sorted component hash
-- =============================================

function OLR.ComputeBinding()
    local tP = {}
    local fList = nil
    pcall(function() fList = component.list end)
    if not fList then pcall(function() fList = raw_component.list end) end
    if fList then
        pcall(function()
            for addr, ctype in fList() do
                tP[#tP + 1] = ctype .. ":" .. addr
            end
        end)
    end
    table.sort(tP)
    return fHash(table.concat(tP, "|"))
end

-- Hardware key: derived from immutable addresses
local function fDeriveHwKey()
    local s = "OLR_HW_KEY:"
    pcall(function() s = s .. computer.address() end)
    pcall(function()
        for a in (raw_component or component).list("eeprom") do s = s .. a; break end
    end)
    pcall(function()
        for a in (raw_component or component).list("data") do s = s .. a; break end
    end)
    return fHash(s)
end

-- =============================================
-- ON-DISK FORMAT (256 bytes, fits one sector)
--
--  [1-4]     Magic "AXOL"
--  [5]       Version
--  [6]       Status (0/1/2)
--  [7-8]     Reserved
--  [9-40]    Owner hash (32B)
--  [41-72]   Machine binding (32B)
--  [73-76]   Timestamp high
--  [77-80]   Timestamp low
--  [81-112]  HW fingerprint (32B)
--  [113-116] Boot counter at lock
--  [117-120] Lock generation
--  [121-152] HMAC of [1-120]
--  [153-256] Reserved
-- =============================================

function OLR.Pack(t, nSS)
    local s = OLR.MAGIC
        .. B.u8(OLR.VERSION)
        .. B.u8(t.nStatus or OLR.STATUS_EMPTY)
        .. B.u16(0)
        .. B.pad(t.sOwnerHash or "", 32)
        .. B.pad(t.sBinding or "", 32)
        .. B.u32(t.nTsHi or 0) .. B.u32(t.nTsLo or 0)
        .. B.pad(t.sHwFP or "", 32)
        .. B.u32(t.nBootAtLock or 0)
        .. B.u32(t.nGeneration or 0)
    s = s .. B.pad(fHmac(fDeriveHwKey(), s), 32)
    return B.pad(s, nSS or 256)
end

function OLR.Unpack(s)
    if not s or #s < 152 then return nil, "too short" end
    if s:sub(1, 4) ~= OLR.MAGIC then return nil, "bad magic" end
    local t = {
        nStatus      = s:byte(6),
        sOwnerHash   = s:sub(9, 40),
        sBinding     = s:sub(41, 72),
        nTsHi        = B.r32(s, 73),
        nTsLo        = B.r32(s, 77),
        sHwFP        = s:sub(81, 112),
        nBootAtLock  = B.r32(s, 113),
        nGeneration  = B.r32(s, 117),
        _sHmac       = s:sub(121, 152),
    }
    t.bValid = fConstEq(
        B.pad(fHmac(fDeriveHwKey(), s:sub(1, 120)), 32),
        t._sHmac)
    return t
end

-- =============================================
-- DISK I/O (raw sector or file)
-- =============================================

function OLR.ReadSector(tDisk, nOff)
    local s = tDisk.readSector(nOff)
    return s and OLR.Unpack(s)
end

function OLR.WriteSector(tDisk, nOff, tRec)
    local ss = tDisk.sectorSize or 512
    local s = OLR.Pack(tRec, ss)
    tDisk.writeSector(nOff, s)
    tDisk.writeSector(nOff + 1, s)  -- mirror
    return true
end

-- File-based fallback (managed FS)
function OLR.ReadFile(oFs, sPath)
    sPath = sPath or "/etc/.olr.dat"
    local h = oFs.open(sPath, "r")
    if not h then return nil end
    local tC = {}
    while true do local c = oFs.read(h, 512); if not c then break end; tC[#tC+1] = c end
    oFs.close(h)
    return OLR.Unpack(table.concat(tC))
end

function OLR.WriteFile(oFs, sPath, tRec)
    sPath = sPath or "/etc/.olr.dat"
    local h = oFs.open(sPath, "w")
    if not h then return false end
    oFs.write(h, OLR.Pack(tRec, 256))
    oFs.close(h)
    return true
end

-- =============================================
-- HIGH-LEVEL API
-- =============================================

function OLR.Setup(tIO, sUser, sPassHash, nBootCtr)
    local tOld
    if tIO.readSector then tOld = OLR.ReadSector(tIO, tIO._off or 0)
    else tOld = OLR.ReadFile(tIO._fs, tIO._path) end

    if tOld and tOld.nStatus == OLR.STATUS_LOCKED then
        return false, "Already locked. Clear first."
    end

    local tRec = {
        nStatus     = OLR.STATUS_LOCKED,
        sOwnerHash  = fHash(sUser .. ":" .. sPassHash),
        sBinding    = OLR.ComputeBinding(),
        nTsLo       = os.time and os.time() or 0,
        nTsHi       = 0,
        sHwFP       = fHash(OLR.ComputeBinding() .. tostring(os.time and os.time() or 0)),
        nBootAtLock = nBootCtr or 0,
        nGeneration = (tOld and tOld.nGeneration or 0) + 1,
    }

    if tIO.readSector then return OLR.WriteSector(tIO, tIO._off or 0, tRec)
    else return OLR.WriteFile(tIO._fs, tIO._path, tRec) end
end

function OLR.Verify(tIO, sUser, sPassHash)
    local tRec
    if tIO.readSector then tRec = OLR.ReadSector(tIO, tIO._off or 0)
    else tRec = OLR.ReadFile(tIO._fs, tIO._path) end

    if not tRec or tRec.nStatus ~= OLR.STATUS_LOCKED then return true end
    if not tRec.bValid then return false, "OLR integrity failed (tampered)" end
    if not fConstEq(tRec.sBinding, OLR.ComputeBinding()) then
        return false, "Machine binding mismatch (different hardware)"
    end
    if not fConstEq(tRec.sOwnerHash, fHash(sUser .. ":" .. sPassHash)) then
        return false, "Owner credentials do not match"
    end
    return true
end

function OLR.Clear(tIO, sUser, sPassHash)
    local bOk, sErr = OLR.Verify(tIO, sUser, sPassHash)
    if not bOk then return false, "Auth required: " .. (sErr or "?") end
    local tRec = { nStatus = OLR.STATUS_CLEARED }
    if tIO.readSector then return OLR.WriteSector(tIO, tIO._off or 0, tRec)
    else return OLR.WriteFile(tIO._fs, tIO._path, tRec) end
end

function OLR.ForceClear(tIO)
    local tRec = { nStatus = OLR.STATUS_CLEARED }
    if tIO.readSector then return OLR.WriteSector(tIO, tIO._off or 0, tRec)
    else return OLR.WriteFile(tIO._fs, tIO._path, tRec) end
end

function OLR.GetStatus(tIO)
    local tRec
    if tIO.readSector then tRec = OLR.ReadSector(tIO, tIO._off or 0)
    else tRec = OLR.ReadFile(tIO._fs, tIO._path) end
    if not tRec then return { bLocked = false } end
    return {
        bLocked    = (tRec.nStatus == OLR.STATUS_LOCKED),
        bIntegrity = tRec.bValid,
        nGen       = tRec.nGeneration,
        nTimestamp = tRec.nTsLo,
    }
end

return OLR