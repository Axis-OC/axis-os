--
-- /boot/kbl_shell.lua
-- KBL v2.0 — Kernel Bootloader Console
-- Fastboot protocol + EFI Shell + A/B Boot Control
--
local C = component
local I = C.invoke
local D = _D
local KO = _K
local PO = _P

local ss = I(D, "getSectorSize")
local function rs(n) return I(D, "readSector", n + 1) end
local function ws(n, d) I(D, "writeSector", n + 1, d) end

local g, scr
for a in C.list("gpu") do g = a; break end
for a in C.list("screen") do scr = a; break end
if g and scr then I(g, "bind", scr) end
local W, H = 80, 25
if g then W, H = I(g, "maxResolution"); I(g, "setResolution", W, H) end

local function r16(s, o) return s:byte(o) * 256 + s:byte(o + 1) end
local function r32(s, o)
    return s:byte(o) * 16777216 + s:byte(o + 1) * 65536
         + s:byte(o + 2) * 256 + s:byte(o + 3)
end
local function ri32(s, o)
    local u = r32(s, o)
    if u >= 2147483648 then return u - 4294967296 end
    return u
end
local function w8(n) return string.char(n % 256) end
local function w16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function w32(n)
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256, n % 256)
end
local function pad(s, n)
    if #s >= n then return s:sub(1, n) end
    return s .. string.rep("\0", n - #s)
end

local ct = {}
for i = 0, 255 do
    local cv = i
    for _ = 1, 8 do
        if cv % 2 == 1 then cv = bit32.bxor(bit32.rshift(cv, 1), 0xEDB88320)
        else cv = bit32.rshift(cv, 1) end
    end
    ct[i] = cv
end
local function crc32(str)
    local cv = 0xFFFFFFFF
    for i = 1, #str do
        cv = bit32.bxor(bit32.rshift(cv, 8), ct[bit32.band(bit32.bxor(cv, str:byte(i)), 0xFF)])
    end
    return bit32.bxor(cv, 0xFFFFFFFF)
end

-- ================================================
-- RDB PARTITION SCAN
-- ================================================

local tParts = {}
local nParts = 0
local BCO, BCS           -- AXBC (Boot Control)

do
    local sRdb = rs(0)
    if sRdb and sRdb:sub(1, 4) == "RDSK" then
        local ns = ri32(sRdb, 25)
        for _ = 1, 16 do
            if ns < 0 then break end
            local q = rs(ns)
            if not q or q:sub(1, 4) ~= "PART" then break end
            local nNL = q:byte(25) or 0
            if nNL > 30 then nNL = 30 end
            local ft = r32(q, 65)
            tParts[nParts] = {
                type   = q:sub(26, 25 + nNL),
                off    = r32(q, 57),
                sz     = r32(q, 61),
                fsType = ft,
                flags  = r32(q, 21),
                pri    = ri32(q, 69),
            }
            if ft == 0x41584243 and not BCO then BCO = r32(q, 57); BCS = r32(q, 61) end
            nParts = nParts + 1
            ns = ri32(q, 17)
        end
    end
end

-- ================================================
-- KBL HEADER
-- ================================================

local tHdr = {}
do
    local kh = rs(KO)
    if kh and kh:sub(1, 4) == "AXKB" then
        tHdr = {
            nVersion      = kh:byte(5),
            nConfig       = kh:byte(6),
            nCodeSize     = r16(kh, 7),
            nCodeCrc      = r32(kh, 9),
            nCodeStart    = r16(kh, 13),
            nCodeCount    = r16(kh, 15),
            nShellStart   = r16(kh, 17),
            nShellCount   = r16(kh, 19),
            nShellSize    = r16(kh, 21),
            nShellCrc     = r32(kh, 23),
            sLabel        = kh:sub(33, 64):gsub("%z", ""),
            nBootAttempts = r32(kh, 65),
            nLastEnter    = r32(kh, 69),
            nKernelFails  = r32(kh, 73),
            nVarStart     = r16(kh, 77),
            nVarCount     = r16(kh, 79),
            nLoaderCrc    = r32(kh, 81),
            sInlineVars   = kh:sub(97, 240),
        }
    end
end

local tReasonNames = {
    f = "force_enter", k = "kernel_fail", s = "bad_superblock",
    a = "no_axfs", missing_ksr = "missing_ksr",
}
local sReason = tReasonNames[_R] or tostring(_R or "unknown")

-- ================================================
-- A/B BOOT CONTROL (AXBC partition)
-- ================================================

local AB_MAGIC = "AXBC"
local SLOT_A, SLOT_B = 0, 1
local STATE_GOOD, STATE_UNVERIFIED, STATE_CORRUPT = 0, 1, 2
local tSlotNames     = { [0] = "a", [1] = "b" }
local tStateNames    = { [0] = "good", [1] = "unverified", [2] = "corrupt" }

local tAB = {
    bPresent       = false,
    nActiveSlot    = SLOT_A,
    nSlotAState    = STATE_UNVERIFIED,
    nSlotBState    = STATE_UNVERIFIED,
    nBootAttempts  = 0,
    nSuccessBoots  = 0,
    nLastVerified  = 0,
    nRollbacks     = 0,
}

local function abRead()
    if not BCO then return end
    local s = rs(BCO)
    if not s or s:sub(1, 4) ~= AB_MAGIC then return end
    tAB.bPresent      = true
    tAB.nActiveSlot    = s:byte(6)
    tAB.nSlotAState    = s:byte(7)
    tAB.nSlotBState    = s:byte(8)
    tAB.nBootAttempts  = r32(s, 9)
    tAB.nSuccessBoots  = r32(s, 13)
    tAB.nLastVerified  = r32(s, 17)
    tAB.nRollbacks     = r32(s, 21)
end

local function abWrite()
    if not BCO then return false end
    local s = AB_MAGIC
        .. w8(1)                        -- version
        .. w8(tAB.nActiveSlot)
        .. w8(tAB.nSlotAState)
        .. w8(tAB.nSlotBState)
        .. w32(tAB.nBootAttempts)
        .. w32(tAB.nSuccessBoots)
        .. w32(tAB.nLastVerified)
        .. w32(tAB.nRollbacks)
    s = pad(s, 120)
    s = s .. w32(crc32(s))
    ws(BCO, pad(s, ss))
    ws(BCO + 1, pad(s, ss))  -- mirror
    return true
end

local function abSlotState(nSlot)
    return nSlot == SLOT_A and tAB.nSlotAState or tAB.nSlotBState
end

abRead()

-- ================================================
-- MINIMAL AXFS v2 READER (for ls / cat)
-- ================================================

local axfs = nil  -- set if PO exists
if PO then
    local sb = rs(PO)
    if not sb or sb:sub(1, 4) ~= "AXF2" then
        sb = rs(PO + 1)
    end
    if sb and sb:sub(1, 4) == "AXF2" then
        local nDS = r16(sb, 20)
        local nIT = r16(sb, 22)
        local ips = math.floor(ss / 80)
        local dpb = math.floor(ss / 32)

        local function readInode(n)
            local sec = nIT + math.floor(n / ips)
            local off = (n % ips) * 80
            local sd = rs(PO + sec)
            if not sd then return nil end
            local o = off + 1
            local fl = sd:byte(o + 22); local ne = sd:byte(o + 23)
            local t = {
                iType = r16(sd, o), size = r32(sd, o + 8),
                flags = fl, nExtents = ne, extents = {},
                indirect = r16(sd, o + 76), inlineData = nil,
            }
            if fl % 2 == 1 then
                t.inlineData = sd:sub(o + 24, o + 24 + math.min(t.size, 52) - 1)
            else
                for i = 1, math.min(ne, 13) do
                    local eo = o + 24 + (i - 1) * 4
                    t.extents[i] = { r16(sd, eo), r16(sd, eo + 2) }
                end
            end
            return t
        end

        local function readBlk(n) return rs(PO + nDS + n) end

        local function iBlocks(t)
            if t.flags % 2 == 1 then return {} end
            local r = {}
            for i = 1, math.min(t.nExtents, 13) do
                local ext = t.extents[i]
                if ext and (ext[1] > 0 or ext[2] > 0) then
                    for j = 0, ext[2] - 1 do r[#r + 1] = ext[1] + j end
                end
            end
            if t.nExtents > 13 and t.indirect > 0 then
                local si = readBlk(t.indirect)
                if si then
                    local ppb = math.floor(ss / 4)
                    for i = 1, ppb do
                        local eS = r16(si, (i - 1) * 4 + 1)
                        local eC = r16(si, (i - 1) * 4 + 3)
                        if eC > 0 then for j = 0, eC - 1 do r[#r + 1] = eS + j end end
                    end
                end
            end
            return r
        end

        local function dirEntries(di)
            local t = {}
            for _, bn in ipairs(iBlocks(di)) do
                local sd = readBlk(bn)
                if sd then
                    for i = 0, dpb - 1 do
                        local o = i * 32 + 1
                        local ino = r16(sd, o)
                        if ino > 0 then
                            local nl = sd:byte(o + 3)
                            local nm = sd:sub(o + 4, o + 3 + nl)
                            local tp = sd:byte(o + 2)
                            t[#t + 1] = { inode = ino, name = nm, iType = tp }
                        end
                    end
                end
            end
            return t
        end

        local function resolve(path)
            local cur = 1
            for seg in path:gmatch("[^/]+") do
                local t = readInode(cur)
                if not t or t.iType ~= 2 then return nil end
                local found = false
                for _, e in ipairs(dirEntries(t)) do
                    if e.name == seg then cur = e.inode; found = true; break end
                end
                if not found then return nil end
            end
            return cur
        end

        local function readFile(path)
            local n = resolve(path)
            if not n then return nil end
            local t = readInode(n)
            if not t or t.iType ~= 1 then return nil end
            if t.flags % 2 == 1 and t.inlineData then
                return t.inlineData:sub(1, t.size)
            end
            local ch = {}; local rem = t.size
            for _, bn in ipairs(iBlocks(t)) do
                local sd = readBlk(bn)
                if sd then ch[#ch + 1] = sd:sub(1, math.min(rem, ss)); rem = rem - ss end
                if rem <= 0 then break end
            end
            return table.concat(ch)
        end

        axfs = {
            readInode   = readInode,
            iBlocks     = iBlocks,
            dirEntries  = dirEntries,
            resolve     = resolve,
            readFile    = readFile,
            nDS         = nDS,
            nIT         = nIT,
        }
    end
end

-- ================================================
-- DISPLAY
-- ================================================

local C_BG     = 0x000000
local C_FG     = 0xBBBBBB
local C_HEAD   = 0x00AAAA
local C_OK     = 0x55FF55
local C_FAIL   = 0xFF5555
local C_WARN   = 0xFFAA00
local C_DIM    = 0x555577
local C_VAL    = 0xFFFFFF
local C_INPUT  = 0xFFFFFF
local C_ACC    = 0x55FFFF

local nOutY = 3
local nMaxOut = H - 2

local function cls()
    if not g then return end
    I(g, "setBackground", C_BG); I(g, "setForeground", C_FG)
    I(g, "fill", 1, 1, W, H, " "); nOutY = 3
end

local function puts(sText, nFg)
    if not g then return end
    if nOutY > nMaxOut then
        I(g, "copy", 1, 4, W, nMaxOut - 3, 0, -1)
        I(g, "fill", 1, nMaxOut, W, 1, " "); nOutY = nMaxOut
    end
    I(g, "setForeground", nFg or C_FG); I(g, "setBackground", C_BG)
    I(g, "set", 1, nOutY, tostring(sText):sub(1, W))
    nOutY = nOutY + 1
end

local function putsf(nFg, sFmt, ...) puts(string.format(sFmt, ...), nFg) end

local function drawHeader()
    if not g then return end
    I(g, "setBackground", 0x001520); I(g, "setForeground", C_HEAD)
    I(g, "fill", 1, 1, W, 1, " ")
    I(g, "set", 2, 1, "KBL v2.0")
    local sSlot = tAB.bPresent
        and ("slot:" .. tSlotNames[tAB.nActiveSlot] .. "(" .. tStateNames[abSlotState(tAB.nActiveSlot)] .. ")")
        or "slot:n/a"
    I(g, "setForeground", C_DIM)
    I(g, "set", W - #sSlot - #sReason - 4, 1, sReason .. " | " .. sSlot)
    I(g, "setBackground", C_BG)
    I(g, "setForeground", C_DIM)
    I(g, "fill", 1, 2, W, 1, "-")
end

local function drawPrompt(sBuf)
    if not g then return end
    I(g, "setBackground", C_BG); I(g, "fill", 1, H, W, 1, " ")
    I(g, "setForeground", C_ACC); I(g, "set", 1, H, "kbl> ")
    I(g, "setForeground", C_INPUT)
    local sD = sBuf or ""
    if #sD > W - 7 then sD = sD:sub(-(W - 7)) end
    I(g, "set", 6, H, sD .. "_")
end

-- ================================================
-- FS TYPE NAMES
-- ================================================

local function fsName(n)
    local tN = {
        [0x41584632] = "AXFS", [0x41584631] = "AXFSv1",
        [0x41584546] = "EFI",  [0x41584F4C] = "OLR",
        [0x41584B53] = "KSR",  [0x41584B42] = "KBL",
        [0x41585642] = "VB",   [0x41584243] = "AXBC",
        [0x4158534E] = "AXSN", [0x53575000] = "Swap", [0] = "Raw",
    }
    return tN[n] or string.format("0x%08X", n)
end

-- ================================================
-- FLAG HELPERS
-- ================================================

local function fmtFlags(n)
    local t = {}
    if bit32.band(n, 0x01) ~= 0 then t[#t + 1] = "FORCE" end
    if bit32.band(n, 0x02) ~= 0 then t[#t + 1] = "FALLBACK" end
    if bit32.band(n, 0x04) ~= 0 then t[#t + 1] = "LOCKED" end
    if bit32.band(n, 0x08) ~= 0 then t[#t + 1] = "VERBOSE" end
    if bit32.band(n, 0x10) ~= 0 then t[#t + 1] = "AUTOCLR" end
    return #t > 0 and table.concat(t, "|") or "none"
end

-- ================================================
-- KBL HEADER WRITE-BACK
-- ================================================

local function writeHdrByte(nOff, nVal)
    local sH = rs(KO)
    if not sH or sH:sub(1, 4) ~= "AXKB" then return false end
    sH = sH:sub(1, nOff - 1) .. string.char(nVal % 256) .. sH:sub(nOff + 1)
    ws(KO, sH); return true
end

local function writeHdrU32(nOff, nVal)
    local sH = rs(KO)
    if not sH or sH:sub(1, 4) ~= "AXKB" then return false end
    sH = sH:sub(1, nOff - 1) .. w32(nVal) .. sH:sub(nOff + 4)
    ws(KO, sH); return true
end

local function patchConfig(nNew)
    writeHdrByte(6, nNew); tHdr.nConfig = nNew
end

-- ================================================
-- INLINE VARIABLES
-- ================================================

local function getInlineVars()
    local tV = {}
    if not tHdr.sInlineVars then return tV end
    for sLine in (tHdr.sInlineVars .. "\n"):gmatch("([^\n]*)\n") do
        local k, v = sLine:match("^([^=]+)=(.*)")
        if k and #k > 0 and k:byte(1) ~= 0 then tV[k] = v end
    end
    return tV
end

local function writeInlineVars(tV)
    local tP = {}
    for k, v in pairs(tV) do tP[#tP + 1] = tostring(k) .. "=" .. tostring(v) end
    local sVars = table.concat(tP, "\n")
    local sH = rs(KO)
    if not sH or sH:sub(1, 4) ~= "AXKB" then return false end
    local sPad = sVars
    if #sPad > 144 then sPad = sPad:sub(1, 144) end
    if #sPad < 144 then sPad = sPad .. string.rep("\0", 144 - #sPad) end
    sH = sH:sub(1, 96) .. sPad .. sH:sub(241)
    ws(KO, sH)
    tHdr.sInlineVars = sPad
    return true
end

-- ================================================
-- GETVAR
-- ================================================

local function getvar(sName)
    -- Device identity
    if sName == "version" then return "2.0"
    elseif sName == "version-bootloader" then return "KBL-2.0-AXFS"
    elseif sName == "serialno" then return computer.address():sub(1, 13)
    elseif sName == "product" then return "AxisOS-UnmanagedDrive"
    elseif sName == "hw-revision" then return "OC-1.7"
    elseif sName == "sector-size" then return tostring(ss)
    elseif sName == "partition-count" then return tostring(nParts)
    -- Security
    elseif sName == "secure" then
        for i = 0, nParts - 1 do
            if tParts[i] and tParts[i].fsType == 0x41584546 then return "yes" end
        end
        return "no"
    elseif sName == "unlocked" then
        return bit32.band(tHdr.nConfig or 0, 0x04) == 0 and "yes" or "no"
    -- Boot state
    elseif sName == "kernel" then
        return sReason == "kernel_fail" and "FAILED" or "not-loaded"
    elseif sName == "boot-reason" then return sReason
    elseif sName == "boot-count" then return tostring(tHdr.nBootAttempts or 0)
    elseif sName == "kernel-fail-count" then return tostring(tHdr.nKernelFails or 0)
    elseif sName == "kbl-config" then return string.format("0x%02X", tHdr.nConfig or 0)
    elseif sName == "kbl-code-size" then return tostring(tHdr.nCodeSize or 0)
    elseif sName == "kbl-code-crc" then return string.format("0x%08X", tHdr.nCodeCrc or 0)
    -- Memory
    elseif sName == "mem-free" then
        return tostring(math.floor(computer.freeMemory() / 1024)) .. "KB"
    elseif sName == "mem-total" then
        return tostring(math.floor(computer.totalMemory() / 1024)) .. "KB"
    elseif sName == "battery" then return "AC"
    elseif sName == "axfs-offset" then return PO and tostring(PO) or "(none)"
    -- A/B slot variables
    elseif sName == "slot-count" then return tAB.bPresent and "2" or "1"
    elseif sName == "current-slot" then
        return tAB.bPresent and tSlotNames[tAB.nActiveSlot] or "a"
    elseif sName == "slot-suffixes" then
        return tAB.bPresent and "a,b" or "a"
    elseif sName == "slot-successful:a" then
        return tAB.bPresent and (tAB.nSlotAState == STATE_GOOD and "yes" or "no") or "yes"
    elseif sName == "slot-successful:b" then
        return tAB.bPresent and (tAB.nSlotBState == STATE_GOOD and "yes" or "no") or "no"
    elseif sName == "slot-unbootable:a" then
        return tAB.bPresent and (tAB.nSlotAState == STATE_CORRUPT and "yes" or "no") or "no"
    elseif sName == "slot-unbootable:b" then
        return tAB.bPresent and (tAB.nSlotBState == STATE_CORRUPT and "yes" or "no") or "yes"
    elseif sName == "slot-retry-count" then
        return tAB.bPresent and tostring(tAB.nBootAttempts) or "0"
    elseif sName == "slot-rollback-count" then
        return tAB.bPresent and tostring(tAB.nRollbacks) or "0"
    end
    -- Dynamic partition queries
    local sPT = sName:match("^partition%-type:(.+)$")
    if sPT then
        for i = 0, nParts - 1 do
            local p = tParts[i]
            if p then
                local sClean = p.type:gsub("%s", "")
                if sClean == sPT or ("p" .. i) == sPT then return fsName(p.fsType or 0) end
            end
        end
        return "(not found)"
    end
    local sPS = sName:match("^partition%-size:(.+)$")
    if sPS then
        for i = 0, nParts - 1 do
            local p = tParts[i]
            if p then
                local sClean = p.type:gsub("%s", "")
                if sClean == sPS or ("p" .. i) == sPS then
                    return tostring((p.sz or 0) * ss) .. "B"
                end
            end
        end
        return "(not found)"
    end
    -- Inline variables
    local tV = getInlineVars()
    if tV[sName] then return tV[sName] end
    return nil
end

-- ================================================
-- COMMANDS
-- ================================================

local bRunning = true
local bContinueBoot = false
local tCmds = {}

function tCmds.help()
    puts("KBL v2.0 — Kernel Bootloader Console", C_ACC)
    puts("")
    puts("Boot:", C_WARN)
    puts("  boot / continue         Attempt kernel boot")
    puts("  reboot                  Full reboot")
    puts("  reboot-bootloader       Reboot into KBL")
    puts("  poweroff                Shutdown")
    puts("")
    puts("Variables:", C_WARN)
    puts("  getvar <name|all>       Query variable")
    puts("  setvar <key>=<value>    Set inline variable")
    puts("")
    if tAB.bPresent then
        puts("A/B Slots:", C_WARN)
        puts("  set_active <a|b>        Switch active boot slot")
        puts("  mark-good [a|b]         Mark slot as verified-good")
        puts("  mark-bad [a|b]          Mark slot as corrupt")
        puts("")
    end
    if axfs then
        puts("Filesystem:", C_WARN)
        puts("  ls [path]               List AXFS directory")
        puts("  cat <path>              Read file contents")
        puts("  hexdump <path> [n]      Hex dump (first n bytes)")
        puts("")
    end
    puts("System:", C_WARN)
    puts("  info                    System information")
    puts("  map / partitions        Partition table")
    puts("  dh / devices            Hardware components")
    puts("  memmap                  Memory usage")
    puts("  verify                  AXFS superblock check")
    puts("  eeprom                  EEPROM status")
    puts("  dmem <sector>           Hex dump raw sector")
    puts("")
    puts("Security:", C_WARN)
    puts("  flashing lock           Lock bootloader")
    puts("  flashing unlock         Unlock bootloader")
    puts("  oem device-info         Extended device info")
    puts("  oem set-flag <name>     Set config flag")
    puts("  oem clear-flag <name>   Clear config flag")
    puts("  oem clear-vars          Clear inline variables")
end

function tCmds.getvar(sArgs)
    if not sArgs or #sArgs == 0 then
        puts("usage: getvar <name> | getvar all", C_FAIL); return
    end
    if sArgs == "all" then
        local tNames = {
            "version", "version-bootloader", "serialno", "product",
            "hw-revision", "secure", "unlocked", "kernel", "boot-reason",
            "current-slot", "slot-count", "slot-suffixes",
            "slot-successful:a", "slot-successful:b",
            "slot-unbootable:a", "slot-unbootable:b",
            "slot-retry-count", "slot-rollback-count",
            "mem-free", "mem-total", "sector-size", "battery",
            "boot-count", "kernel-fail-count", "kbl-config",
            "kbl-code-size", "kbl-code-crc", "partition-count", "axfs-offset",
        }
        for _, sN in ipairs(tNames) do
            local sV = getvar(sN)
            if sV then putsf(C_FG, "%-24s: %s", sN, sV) end
        end
        -- Partition variables
        for i = 0, nParts - 1 do
            local p = tParts[i]
            if p then
                local sN = p.type:gsub("%s", "")
                if #sN == 0 then sN = "p" .. i end
                putsf(C_DIM, "partition-type:%-9s: %s", sN, fsName(p.fsType or 0))
            end
        end
        -- Inline vars
        local tV = getInlineVars()
        local bHave = false
        for _ in pairs(tV) do bHave = true; break end
        if bHave then
            puts(""); puts("Inline variables:", C_DIM)
            for k, v in pairs(tV) do putsf(C_DIM, "  %-20s= %s", k, v) end
        end
        return
    end
    local sV = getvar(sArgs)
    putsf(sV and C_OK or C_FAIL, "%s: %s", sArgs, sV or "(not found)")
end

function tCmds.setvar(sArgs)
    if not sArgs or not sArgs:find("=") then
        puts("usage: setvar key=value", C_FAIL); return
    end
    local k, v = sArgs:match("^([^=]+)=(.*)")
    if not k or #k == 0 then puts("bad key", C_FAIL); return end
    local tV = getInlineVars()
    tV[k] = v
    if writeInlineVars(tV) then
        putsf(C_OK, "%s = %s", k, v)
    else
        puts("write failed", C_FAIL)
    end
end

function tCmds.boot()
    puts("Continuing boot...", C_OK)
    bContinueBoot = true; bRunning = false
end
tCmds["continue"] = tCmds.boot

function tCmds.reboot()
    puts("Rebooting...", C_WARN)
    computer.beep(800, 0.1); computer.shutdown(true)
end

function tCmds.poweroff()
    puts("Shutting down...", C_WARN)
    computer.beep(400, 0.2); computer.shutdown(false)
end

tCmds["reboot-bootloader"] = function()
    puts("Setting force-enter flag...", C_WARN)
    patchConfig(bit32.bor(tHdr.nConfig or 0, 0x01))
    computer.beep(800, 0.1); computer.shutdown(true)
end

-- ================================================
-- A/B SLOT COMMANDS
-- ================================================

tCmds["set_active"] = function(sArgs)
    if not tAB.bPresent then
        puts("FAIL: No AXBC partition — A/B not available", C_FAIL); return
    end
    local sSlot = (sArgs or ""):lower():gsub("%s", "")
    if sSlot ~= "a" and sSlot ~= "b" then
        puts("usage: set_active <a|b>", C_FAIL); return
    end
    local nNew = sSlot == "a" and SLOT_A or SLOT_B
    tAB.nActiveSlot = nNew
    tAB.nBootAttempts = 0  -- reset boot attempts on slot switch
    if abWrite() then
        putsf(C_OK, "Active slot set to '%s'", sSlot)
        drawHeader()
    else
        puts("FAIL: Could not write AXBC", C_FAIL)
    end
end

tCmds["mark-good"] = function(sArgs)
    if not tAB.bPresent then puts("FAIL: No AXBC", C_FAIL); return end
    local sSlot = (sArgs or ""):lower():gsub("%s", "")
    if sSlot == "" then sSlot = tSlotNames[tAB.nActiveSlot] end
    if sSlot ~= "a" and sSlot ~= "b" then
        puts("usage: mark-good [a|b]", C_FAIL); return
    end
    if sSlot == "a" then tAB.nSlotAState = STATE_GOOD
    else tAB.nSlotBState = STATE_GOOD end
    tAB.nSuccessBoots = tAB.nSuccessBoots + 1
    if abWrite() then
        putsf(C_OK, "Slot '%s' marked as good", sSlot)
        drawHeader()
    else puts("FAIL: Write error", C_FAIL) end
end

tCmds["mark-bad"] = function(sArgs)
    if not tAB.bPresent then puts("FAIL: No AXBC", C_FAIL); return end
    local sSlot = (sArgs or ""):lower():gsub("%s", "")
    if sSlot == "" then sSlot = tSlotNames[tAB.nActiveSlot] end
    if sSlot ~= "a" and sSlot ~= "b" then
        puts("usage: mark-bad [a|b]", C_FAIL); return
    end
    if sSlot == "a" then tAB.nSlotAState = STATE_CORRUPT
    else tAB.nSlotBState = STATE_CORRUPT end
    if abWrite() then
        putsf(C_WARN, "Slot '%s' marked as corrupt", sSlot)
        drawHeader()
    else puts("FAIL: Write error", C_FAIL) end
end

-- ================================================
-- SYSTEM INFO COMMANDS
-- ================================================

function tCmds.info()
    puts("=== System Information ===", C_ACC)
    putsf(C_FG, "Serial:       %s", computer.address():sub(1, 13))
    putsf(C_FG, "Memory:       %dKB / %dKB",
        math.floor(computer.freeMemory() / 1024),
        math.floor(computer.totalMemory() / 1024))
    putsf(C_FG, "Uptime:       %.1fs", computer.uptime())
    putsf(C_FG, "Sector size:  %dB", ss)
    putsf(C_FG, "KBL version:  %d", tHdr.nVersion or 0)
    putsf(C_FG, "KBL config:   0x%02X (%s)", tHdr.nConfig or 0, fmtFlags(tHdr.nConfig or 0))
    putsf(C_FG, "Boot reason:  %s", sReason)
    putsf(C_FG, "AXFS:         %s", PO and ("sector " .. PO) or "NOT FOUND")
    putsf(C_FG, "Partitions:   %d", nParts)
    if tAB.bPresent then
        puts("")
        puts("A/B Boot Control:", C_ACC)
        putsf(C_FG, "  Active slot:   %s", tSlotNames[tAB.nActiveSlot])
        putsf(C_FG, "  Slot A:        %s", tStateNames[tAB.nSlotAState])
        putsf(C_FG, "  Slot B:        %s", tStateNames[tAB.nSlotBState])
        putsf(C_FG, "  Boot attempts: %d", tAB.nBootAttempts)
        putsf(C_FG, "  Good boots:    %d", tAB.nSuccessBoots)
        putsf(C_FG, "  Rollbacks:     %d", tAB.nRollbacks)
    end
end

function tCmds.devices() tCmds.dh() end
function tCmds.dh()
    puts("=== Device Handles ===", C_ACC)
    putsf(C_FG, "%-3s %-8s %s", "#", "ADDRESS", "TYPE")
    puts(string.rep("-", 40), C_DIM)
    local n = 0
    for addr, ctype in C.list() do
        n = n + 1
        putsf(C_FG, "%3d %s %s", n, addr:sub(1, 8), ctype)
    end
    putsf(C_DIM, "Total: %d device(s)", n)
end

function tCmds.map() tCmds.partitions() end
function tCmds.partitions()
    puts("=== RDB Partition Map ===", C_ACC)
    putsf(C_FG, "%-3s %-10s %-8s %8s %10s %5s",
        "#", "NAME", "TYPE", "START", "SIZE", "FLAGS")
    puts(string.rep("-", 52), C_DIM)
    for i = 0, nParts - 1 do
        local p = tParts[i]
        if p then
            local sN = p.type:gsub("%s", "")
            if #sN == 0 then sN = "p" .. i end
            local sMark = ""
            if tAB.bPresent and p.fsType == 0x41584632 then
                sMark = tAB.nActiveSlot == SLOT_A and " [A]" or ""
            end
            putsf(C_FG, "%3d %-10s %-8s %8d %8dB 0x%02X%s",
                i, sN, fsName(p.fsType or 0),
                p.off or 0, (p.sz or 0) * ss, p.flags or 0, sMark)
        end
    end
end

function tCmds.memmap()
    puts("=== Memory Map ===", C_ACC)
    local nTotal = computer.totalMemory()
    local nFree  = computer.freeMemory()
    local nUsed  = nTotal - nFree
    local nPct   = math.floor(nUsed / nTotal * 100)
    putsf(C_FG, "Total:    %8d B  (%d KB)", nTotal, math.floor(nTotal / 1024))
    putsf(C_FG, "Used:     %8d B  (%d KB)  %d%%", nUsed, math.floor(nUsed / 1024), nPct)
    putsf(C_FG, "Free:     %8d B  (%d KB)  %d%%", nFree, math.floor(nFree / 1024), 100 - nPct)
    puts("")
    -- Visual bar
    local nBarW = W - 12
    local nFilled = math.floor(nPct / 100 * nBarW)
    local sBar = "[" .. string.rep("#", nFilled) .. string.rep(".", nBarW - nFilled) .. "]"
    local nBarColor = nPct > 90 and C_FAIL or (nPct > 70 and C_WARN or C_OK)
    putsf(nBarColor, "  %s %d%%", sBar, nPct)
end

function tCmds.eeprom()
    puts("=== EEPROM ===", C_ACC)
    local ep; for a in C.list("eeprom") do ep = a; break end
    if not ep then puts("No EEPROM", C_FAIL); return end
    putsf(C_FG, "Address: %s", ep:sub(1, 13))
    putsf(C_FG, "Label:   %s", I(ep, "getLabel") or "?")
    local sD = I(ep, "getData") or ""
    putsf(C_FG, "Data:    %dB  magic=%s", #sD, #sD >= 4 and sD:sub(1, 4) or "?")
    putsf(C_FG, "Code:    %dB", #(I(ep, "get") or ""))
end

function tCmds.verify()
    puts("=== AXFS Superblock Verification ===", C_ACC)
    if not PO then puts("No AXFS partition found.", C_FAIL); return end
    putsf(C_FG, "AXFS partition at sector %d", PO)
    local sb = rs(PO)
    if not sb or sb:sub(1, 4) ~= "AXF2" then
        local sb2 = rs(PO + 1)
        if sb2 and sb2:sub(1, 4) == "AXF2" then
            puts("Primary SB bad, mirror OK", C_WARN); sb = sb2
        else puts("Both superblocks invalid", C_FAIL); return end
    else puts("Primary superblock: OK", C_OK) end

    putsf(C_FG, "  Version:    %d", sb:byte(5))
    putsf(C_FG, "  Sector sz:  %d", r16(sb, 6))
    putsf(C_FG, "  Total sec:  %d", r32(sb, 8))
    putsf(C_FG, "  Inodes:     %d max, %d free", r16(sb, 12), r16(sb, 16))
    putsf(C_FG, "  Blocks:     %d max, %d free", r16(sb, 14), r16(sb, 18))
    putsf(C_FG, "  DataStart:  %d", r16(sb, 20))
    putsf(C_FG, "  ItableStart:%d", r16(sb, 22))
    local sLabel = sb:sub(27, 42):gsub("%z", "")
    putsf(C_FG, "  Label:      %s", sLabel)
    if #sb >= 60 then
        local nStored = r32(sb, 57)
        local nCalc = crc32(sb:sub(1, 56))
        putsf(nStored == nCalc and C_OK or C_FAIL,
            "  SB CRC:     %s (0x%08X)", nStored == nCalc and "OK" or "MISMATCH", nStored)
    end
end

-- ================================================
-- FILESYSTEM COMMANDS (AXFS)
-- ================================================

function tCmds.ls(sArgs)
    if not axfs then puts("No AXFS available", C_FAIL); return end
    local sPath = sArgs or "/"
    if #sPath == 0 then sPath = "/" end
    local n = axfs.resolve(sPath)
    if not n then putsf(C_FAIL, "Not found: %s", sPath); return end
    local t = axfs.readInode(n)
    if not t or t.iType ~= 2 then putsf(C_FAIL, "Not a directory: %s", sPath); return end

    putsf(C_ACC, "Directory: %s", sPath)
    putsf(C_DIM, "%-4s %8s  %s", "TYPE", "SIZE", "NAME")
    puts(string.rep("-", 36), C_DIM)

    local tEnts = axfs.dirEntries(t)
    table.sort(tEnts, function(a, b) return a.name < b.name end)
    for _, e in ipairs(tEnts) do
        if e.name ~= "." and e.name ~= ".." then
            local ci = axfs.readInode(e.inode)
            local sType = (e.iType == 2 or (ci and ci.iType == 2)) and "DIR" or "FILE"
            local nSize = ci and ci.size or 0
            local nColor = sType == "DIR" and C_ACC or C_FG
            putsf(nColor, "%-4s %8d  %s%s", sType, nSize, e.name,
                sType == "DIR" and "/" or "")
        end
    end
end

function tCmds.cat(sArgs)
    if not axfs then puts("No AXFS available", C_FAIL); return end
    if not sArgs or #sArgs == 0 then puts("usage: cat <path>", C_FAIL); return end
    local sData = axfs.readFile(sArgs)
    if not sData then putsf(C_FAIL, "Not found: %s", sArgs); return end
    -- Print line by line (truncate long lines, limit output)
    local nLines = 0
    for sLine in (sData .. "\n"):gmatch("([^\n]*)\n") do
        if nLines > 50 then
            putsf(C_DIM, "... truncated (%d bytes total)", #sData)
            break
        end
        if #sLine > W then sLine = sLine:sub(1, W - 3) .. "..." end
        puts(sLine, C_FG)
        nLines = nLines + 1
    end
end

function tCmds.hexdump(sArgs)
    if not axfs then puts("No AXFS available", C_FAIL); return end
    if not sArgs or #sArgs == 0 then puts("usage: hexdump <path> [n]", C_FAIL); return end
    local sPath, sN = sArgs:match("^(%S+)%s*(%S*)")
    local nMax = tonumber(sN) or 128
    local sData = axfs.readFile(sPath)
    if not sData then putsf(C_FAIL, "Not found: %s", sPath); return end
    putsf(C_ACC, "%s (%d bytes, showing %d):", sPath, #sData, math.min(#sData, nMax))
    local nShow = math.min(#sData, nMax)
    for row = 0, nShow - 1, 16 do
        local tHex, tAsc = {}, {}
        for col = 0, 15 do
            local idx = row + col + 1
            if idx <= nShow then
                local b = sData:byte(idx)
                tHex[#tHex + 1] = string.format("%02X", b)
                tAsc[#tAsc + 1] = (b >= 32 and b < 127) and string.char(b) or "."
            else
                tHex[#tHex + 1] = "  "; tAsc[#tAsc + 1] = " "
            end
        end
        putsf(C_DIM, "%04X: %s  %s", row, table.concat(tHex, " "), table.concat(tAsc))
    end
end

-- ================================================
-- SECTOR DUMP
-- ================================================

function tCmds.dmem(sArgs)
    local nSec = tonumber(sArgs)
    if not nSec then puts("usage: dmem <sector>", C_FAIL); return end
    local sD = rs(nSec)
    if not sD then puts("Read failed", C_FAIL); return end
    putsf(C_ACC, "Sector %d (%d bytes):", nSec, #sD)
    local nShow = math.min(#sD, 128)
    for row = 0, nShow - 1, 16 do
        local tHex, tAsc = {}, {}
        for col = 0, 15 do
            local idx = row + col + 1
            if idx <= nShow then
                local b = sD:byte(idx)
                tHex[#tHex + 1] = string.format("%02X", b)
                tAsc[#tAsc + 1] = (b >= 32 and b < 127) and string.char(b) or "."
            else tHex[#tHex + 1] = "  "; tAsc[#tAsc + 1] = " " end
        end
        putsf(C_DIM, "%04X: %s  %s", row, table.concat(tHex, " "), table.concat(tAsc))
    end
    if #sD > nShow then putsf(C_DIM, "... +%d bytes", #sD - nShow) end
end

-- ================================================
-- SECURITY COMMANDS
-- ================================================

function tCmds.flashing(sArgs)
    if not sArgs then puts("usage: flashing <lock|unlock>", C_FAIL); return end
    local sub = sArgs:lower():gsub("%s", "")
    if sub == "unlock" then
        patchConfig(bit32.band(tHdr.nConfig or 0, bit32.bnot(0x04)))
        puts("Bootloader unlocked.", C_WARN)
        putsf(C_DIM, "Config: 0x%02X", tHdr.nConfig)
    elseif sub == "lock" then
        patchConfig(bit32.bor(tHdr.nConfig or 0, 0x04))
        puts("Bootloader locked.", C_OK)
        putsf(C_DIM, "Config: 0x%02X", tHdr.nConfig)
    else puts("usage: flashing <lock|unlock>", C_FAIL) end
end

function tCmds.oem(sArgs)
    if not sArgs or #sArgs == 0 then puts("usage: oem <subcmd>", C_FAIL); return end
    local sub, arg = sArgs:match("^(%S+)%s*(.*)")

    if sub == "device-info" then
        tCmds.info()
        puts("")
        if g then
            local nMW, nMH = I(g, "maxResolution")
            putsf(C_FG, "GPU: %s  max=%dx%d", g:sub(1, 8), nMW or 0, nMH or 0)
        end
        for addr in C.list("drive") do
            putsf(C_FG, "Drive: %s  %dKB  %dB/sec",
                addr:sub(1, 8), math.floor(I(addr, "getCapacity") / 1024),
                I(addr, "getSectorSize"))
        end

    elseif sub == "set-flag" then
        local tFM = {
            force=0x01, fallback=0x02, locked=0x04,
            verbose=0x08, auto_clear=0x10, autoclear=0x10,
        }
        local nF = tFM[(arg or ""):lower()] or tonumber(arg)
        if not nF then puts("Unknown flag: " .. arg, C_FAIL); return end
        patchConfig(bit32.bor(tHdr.nConfig or 0, nF))
        putsf(C_OK, "Config: 0x%02X (%s)", tHdr.nConfig, fmtFlags(tHdr.nConfig))

    elseif sub == "clear-flag" then
        local tFM = {
            force=0x01, fallback=0x02, locked=0x04,
            verbose=0x08, auto_clear=0x10, autoclear=0x10,
        }
        local nF = tFM[(arg or ""):lower()] or tonumber(arg)
        if not nF then puts("Unknown flag: " .. arg, C_FAIL); return end
        patchConfig(bit32.band(tHdr.nConfig or 0, bit32.bnot(nF)))
        putsf(C_OK, "Config: 0x%02X (%s)", tHdr.nConfig, fmtFlags(tHdr.nConfig))

    elseif sub == "clear-vars" then
        writeInlineVars({})
        puts("Inline variables cleared.", C_OK)

    else putsf(C_FAIL, "Unknown OEM command: %s", sub) end
end

-- ================================================
-- INPUT
-- ================================================

local tHistory = {}
local nHistIdx = 0

local function readLine()
    local sBuf = ""
    nHistIdx = #tHistory + 1
    drawPrompt(sBuf)
    while true do
        local ev, _, ch, code = computer.pullSignal(0.5)
        if ev == "key_down" then
            if code == 28 then
                if #sBuf > 0 then
                    tHistory[#tHistory + 1] = sBuf
                    if #tHistory > 32 then table.remove(tHistory, 1) end
                end
                return sBuf
            elseif code == 14 then
                if #sBuf > 0 then sBuf = sBuf:sub(1, -2) end
            elseif code == 200 then
                if nHistIdx > 1 then nHistIdx = nHistIdx - 1; sBuf = tHistory[nHistIdx] or "" end
            elseif code == 208 then
                if nHistIdx <= #tHistory then
                    nHistIdx = nHistIdx + 1; sBuf = tHistory[nHistIdx] or ""
                end
            elseif ch and ch >= 32 and ch < 127 then
                sBuf = sBuf .. string.char(ch)
            end
            drawPrompt(sBuf)
        end
    end
end

-- ================================================
-- RECORD ENTRY IN KBL COUNTERS
-- ================================================

do
    local nBa = (tHdr.nBootAttempts or 0) + 1
    writeHdrU32(65, nBa)
    tHdr.nBootAttempts = nBa
    if bit32.band(tHdr.nConfig or 0, 0x10) ~= 0
       and bit32.band(tHdr.nConfig or 0, 0x01) ~= 0 then
        patchConfig(bit32.band(tHdr.nConfig, bit32.bnot(0x01)))
    end
end

-- ================================================
-- SPLASH
-- ================================================

cls(); drawHeader()
puts("")
puts("AxisOS Kernel Bootloader v2.0", C_ACC)
putsf(C_FG, "Serial: %s   HW: OC-1.7", computer.address():sub(1, 13))
putsf(C_FG, "Memory: %dKB free / %dKB total",
    math.floor(computer.freeMemory() / 1024),
    math.floor(computer.totalMemory() / 1024))
putsf(C_FG, "Config: 0x%02X (%s)", tHdr.nConfig or 0, fmtFlags(tHdr.nConfig or 0))
putsf(C_FG, "Reason: %s", sReason)
if tAB.bPresent then
    putsf(C_FG, "Active slot: %s (%s)   Slot A: %-12s Slot B: %s",
        tSlotNames[tAB.nActiveSlot], tStateNames[abSlotState(tAB.nActiveSlot)],
        tStateNames[tAB.nSlotAState], tStateNames[tAB.nSlotBState])
    putsf(C_FG, "Boot attempts: %d   Rollbacks: %d", tAB.nBootAttempts, tAB.nRollbacks)
else
    puts("A/B: No AXBC partition (single-slot mode)", C_DIM)
end
if sReason == "kernel_fail" then
    puts(""); puts("WARNING: Kernel loading failed.", C_FAIL)
    putsf(C_WARN, "Kernel failures: %d", tHdr.nKernelFails or 0)
elseif sReason == "bad_superblock" then
    puts(""); puts("WARNING: AXFS superblock corrupt.", C_FAIL)
elseif sReason == "no_axfs" then
    puts(""); puts("WARNING: No AXFS partition found.", C_FAIL)
end
puts("")
puts("Type 'help' for commands.", C_DIM)
computer.beep(600, 0.1)

-- ================================================
-- MAIN LOOP
-- ================================================

while bRunning do
    local sLine = readLine()
    if sLine and #sLine > 0 then
        local sCmd, sArgs = sLine:match("^(%S+)%s*(.*)")
        sCmd = sCmd and sCmd:lower() or ""
        putsf(C_DIM, "kbl> %s", sLine)
        local f = tCmds[sCmd]
        if f then
            local nT0 = computer.uptime()
            local bOk, sErr = pcall(f, (#sArgs > 0) and sArgs or nil)
            local nElapsed = computer.uptime() - nT0
            if not bOk then putsf(C_FAIL, "Error: %s", tostring(sErr)) end
        elseif #sCmd > 0 then
            putsf(C_FAIL, "Unknown: %s", sCmd)
            puts("Type 'help' for commands.", C_DIM)
        end
    end
end

return bContinueBoot