--
-- /boot/sys/stage2_boot.lua
-- AxisOS KBL Stage2 Bootloader v1.1
-- A/B boot control via AXBC partition
--

local C = component
local I = C.invoke
local D = _drive
local ss = _ss
local KO = _kbl_off

local g, scr
for a in C.list("gpu") do g = a; break end
for a in C.list("screen") do scr = a; break end
local W, H = 80, 25
if g then W, H = I(g, "maxResolution") end
local cy = 6
local function p(t, c)
    if g then I(g, "setForeground", c or 0xFFFFFF); I(g, "set", 1, cy, t); cy = cy + 1 end
end
local function die(m)
    p("HALT: " .. m, 0xFF0000)
    computer.beep(200, 1)
    while true do computer.pullSignal(1) end
end

local function rs(n) return I(D, "readSector", n + 1) end
local function r16(s, o) return s:byte(o) * 256 + s:byte(o + 1) end
local function r32(s, o)
    return s:byte(o) * 0x1000000 + s:byte(o + 1) * 0x10000
         + s:byte(o + 2) * 0x100 + s:byte(o + 3)
end
local function ri32(s, o)
    local u = r32(s, o); if u >= 2147483648 then return u - 4294967296 end; return u
end
local function w32(n)
    return string.char(math.floor(n/16777216)%256, math.floor(n/65536)%256,
        math.floor(n/256)%256, n%256)
end

local ct = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        if c % 2 == 1 then c = bit32.bxor(bit32.rshift(c, 1), 0xEDB88320)
        else c = bit32.rshift(c, 1) end
    end
    ct[i] = c
end
local function crc32(s)
    local c = 0xFFFFFFFF
    for i = 1, #s do
        c = bit32.bxor(bit32.rshift(c, 8), ct[bit32.band(bit32.bxor(c, s:byte(i)), 0xFF)])
    end
    return bit32.bxor(c, 0xFFFFFFFF)
end

-- =============================================
-- STEP 1: WALK RDB
-- =============================================
p("Scanning partitions...", 0xAAAAAA)

local tParts = {}
local nParts = 0
local PO, PS
local KSO, KSS
local EO, ES
local VBO, VBS
local BCO, BCS  -- [A/B] Boot Control partition
local PO_A, PS_A
local PO_B, PS_B

do
    local rdb = _rdb
    if rdb and rdb:sub(1, 4) == "RDSK" then
        local ns = ri32(rdb, 25)
        for _ = 1, 16 do
            if ns < 0 then break end
            local q = rs(ns)
            if not q or q:sub(1, 4) ~= "PART" then break end
            local nNL = q:byte(25) or 0; if nNL > 30 then nNL = 30 end
            local ft = r32(q, 65)
            local off = r32(q, 57)
            local sz = r32(q, 61)
            tParts[nParts] = {
                type = q:sub(26, 25 + nNL),
                off = off, sz = sz, fsType = ft,
                flags = r32(q, 21), pri = ri32(q, 69),
            }
            if ft == 0x41584632 and not PO then PO = off; PS = sz end
            if ft == 0x41584B53 then KSO = off; KSS = sz end
            if ft == 0x41584546 then EO = off; ES = sz end
            if ft == 0x41585642 then VBO = off; VBS = sz end
            if ft == 0x41584243 then BCO = off; BCS = sz end  -- [A/B]
            if ft == 0x41584632 then  -- AXFS v2
                if not PO_A then
                    PO_A = off; PS_A = sz
                elseif not PO_B then
                    PO_B = off; PS_B = sz
                end
            end
            nParts = nParts + 1
            ns = ri32(q, 17)
        end
    end
end

-- =============================================
-- STEP 2: VALIDATE KSR
-- =============================================
if not KSO then
    p("", 0xFF0000)
    p("ERROR: KSR partition NOT FOUND", 0xFF0000)
    p("Entering KBL recovery shell...", 0x55FFFF)
    computer.beep(400, 0.3)
    local kh = _kbl_hdr
    local nShStart = r16(kh, 17)
    local nShCount = r16(kh, 19)
    local nShSize  = r16(kh, 21)
    if nShSize > 0 and nShCount > 0 then
        local tSh = {}
        for i = 0, nShCount - 1 do
            tSh[#tSh + 1] = rs(KO + nShStart + i) or ""
        end
        local sShell = table.concat(tSh):sub(1, nShSize)
        local e = {
            _D = D, _K = KO, _P = PO, _R = "missing_ksr",
            component = C, computer = computer, bit32 = bit32,
            math = math, string = string, table = table, os = os,
            pairs = pairs, ipairs = ipairs, type = type,
            tostring = tostring, tonumber = tonumber,
            pcall = pcall, error = error, load = load,
            setmetatable = setmetatable, next = next,
            select = select, rawset = rawset, rawget = rawget,
        }
        setmetatable(e, { __index = _G }); e._G = e
        local f = load(sShell, "=kbl", "t", e)
        if f then
            local bOk, vR = pcall(f)
            if not bOk then p("KBL CRASH: " .. tostring(vR):sub(1, W - 2), 0xFF5555) end
            if vR == false then die("User exited KBL") end
        else die("KBL shell parse error") end
    else die("No KBL shell code available") end
end

-- =============================================
-- STEP 3: Read config from KBL header
-- =============================================
local tConfig = {
    nSbMode       = 0,
    nDefaultEntry = 0,
    nTimeout      = 3,
    nQuickBoot    = 0,
    nLogLevel     = 2,
}
do
    local kh = _kbl_hdr
    if #kh >= 504 and kh:sub(257, 260) == "AXEO" then
        tConfig.nSbMode       = kh:byte(261) or 0
        tConfig.nDefaultEntry = kh:byte(262) or 0
        tConfig.nTimeout      = kh:byte(263) or 3
        tConfig.nQuickBoot    = kh:byte(264) or 0
        tConfig.nLogLevel     = kh:byte(265) or 2
        p("Config loaded from KBL", 0xAAAAAA)
    end
end

-- =============================================
-- STEP 4: Read loader.cfg
-- =============================================
local tLoaderCfg = nil
do
    local kh = _kbl_hdr
    local nLcStart = r16(kh, 27)
    local nLcCount = r16(kh, 29)
    local nLcSize  = r16(kh, 31)
    if nLcSize > 0 and nLcCount > 0 then
        local tLc = {}
        for i = 0, nLcCount - 1 do
            tLc[#tLc + 1] = rs(KO + nLcStart + i) or ""
        end
        local sLcCode = table.concat(tLc):sub(1, nLcSize)
        local nLcCrc = r32(kh, 81)
        if nLcCrc == 0 or crc32(sLcCode) == nLcCrc then
            local f = load(sLcCode, "loader.cfg", "t", {})
            if f then
                local bOk, tR = pcall(f)
                if bOk and type(tR) == "table" then
                    tLoaderCfg = tR
                    p("loader.cfg loaded from KBL", 0xAAAAAA)
                end
            end
        else p("loader.cfg CRC mismatch!", 0xFFAA00) end
    end
end

if not tLoaderCfg then
    tLoaderCfg = {
        timeout = tConfig.nTimeout, default = "axis",
        entries = {{ id = "axis", title = "AxisOS",
            kernel = "/kernel.lua", init = "/bin/init.lua",
            params = { loglevel = "Info" },
        }},
    }
    p("Using default boot config", 0xFFAA00)
end

local entries = tLoaderCfg.entries or {}
local sel = 1
local kc

local nActiveSlot     = 0
local nSlotAState     = 1
local nSlotBState     = 1
local nAbBootAttempts = 0
local nAbRollbacks    = 0
local bAbPresent      = false

local bKernelCrashed  = false

-- =============================================
-- STEP 5: Check force-enter KBL flag
-- =============================================
do
    local nCfgFlags = _kbl_hdr:byte(6) or 0
    if nCfgFlags % 2 == 1 then
        p("KBL forced entry flag detected", 0xFFFF55)
        if math.floor(nCfgFlags / 16) % 2 == 1 then
            local sH = rs(KO)
            if sH then
                local nNew = bit32.band(nCfgFlags, bit32.bnot(0x01))
                sH = sH:sub(1, 5) .. string.char(nNew) .. sH:sub(7)
                I(D, "writeSector", KO + 1, sH)
            end
        end
        goto enter_kbl_shell
    end
end

-- =============================================
-- STEP 5.5: A/B BOOT CONTROL  [NEW]
-- =============================================

if BCO then
    local sBC = rs(BCO)
    if not sBC or sBC:sub(1, 4) ~= "AXBC" then
        -- Initialize fresh AXBC with both slots UNVERIFIED
        p("A/B: Initializing AXBC partition...", 0xFFFF55)
        local sInit = "AXBC"
            .. string.char(1)       -- version
            .. string.char(0)       -- active = slot A
            .. string.char(1)       -- slot A = UNVERIFIED
            .. string.char(1)       -- slot B = UNVERIFIED
            .. w32(0)               -- boot attempts
            .. w32(0)               -- success boots
            .. w32(0)               -- last verified
            .. w32(0)               -- rollbacks
        sInit = sInit .. string.rep("\0", ss - #sInit)
        I(D, "writeSector", BCO + 1, sInit)
        sBC = rs(BCO) -- re-read
    end

    if sBC and sBC:sub(1, 4) == "AXBC" then
        bAbPresent      = true
        nActiveSlot     = sBC:byte(6) or 0
        nSlotAState     = sBC:byte(7) or 1
        nSlotBState     = sBC:byte(8) or 1
        nAbBootAttempts = r32(sBC, 9)
        nAbRollbacks    = r32(sBC, 21)

        nAbBootAttempts = nAbBootAttempts + 1

        local nActiveState = nActiveSlot == 0 and nSlotAState or nSlotBState
        if nAbBootAttempts >= 3 and nActiveState ~= 0 then
            local nOldSlot = nActiveSlot
            -- Only rollback if OTHER slot isn't also corrupt
            local nOtherState = nActiveSlot == 0 and nSlotBState or nSlotAState
            if nOtherState ~= 2 then
                nActiveSlot = 1 - nActiveSlot
                nAbBootAttempts = 0
                nAbRollbacks = nAbRollbacks + 1
                p("A/B: Rollback " ..
                    (nOldSlot == 0 and "a" or "b") .. " -> " ..
                    (nActiveSlot == 0 and "a" or "b") ..
                    " (3 failed boots)", 0xFFAA00)
            else
                p("A/B: Both slots degraded — cannot rollback", 0xFF5555)
            end
        end

        local sNew = "AXBC"
            .. string.char(1)
            .. string.char(nActiveSlot)
            .. string.char(nSlotAState)
            .. string.char(nSlotBState)
            .. w32(nAbBootAttempts)
            .. sBC:sub(13, 20)
            .. w32(nAbRollbacks)
            .. sBC:sub(25)
        I(D, "writeSector", BCO + 1, sNew)

        local tSN = {[0]="a", [1]="b"}
        local tSS = {[0]="good", [1]="unverified", [2]="corrupt"}
        p("A/B: slot=" .. tSN[nActiveSlot] ..
          " state=" .. (tSS[nActiveSlot == 0 and nSlotAState or nSlotBState] or "?") ..
          " attempt=" .. nAbBootAttempts, 0xAAAAAA)
    end
end

if bAbPresent and nActiveSlot == 1 and PO_B then
    PO = PO_B; PS = PS_B
    p("A/B: Booting from slot B (AXFS @ sector " .. PO .. ")", 0xAAAAAA)
elseif PO_A then
    PO = PO_A; PS = PS_A
    if bAbPresent then
        p("A/B: Booting from slot A (AXFS @ sector " .. PO .. ")", 0xAAAAAA)
    end
else
    PO = nil  -- will trigger "No AXFS" error in Step 8
end

-- =============================================
-- STEP 6: BIOS SETUP
-- =============================================
if _setup_requested then end

-- =============================================
-- STEP 7: Boot menu
-- =============================================
entries = tLoaderCfg.entries or {}
sel = 1

for i, e in ipairs(entries) do
    if e.id == tLoaderCfg.default then sel = i; break end
end
if tConfig.nDefaultEntry > 0 and tConfig.nDefaultEntry <= #entries then
    sel = tConfig.nDefaultEntry
end

if #entries > 1 and not _setup_requested then
    if g then
        I(g, "setBackground", 0); I(g, "setForeground", 0xFFFFFF)
        I(g, "fill", 1, 1, W, H, " ")
        I(g, "setForeground", 0x00AAAA)
        I(g, "set", 2, 1, "AxisOS Boot Menu")
        if bAbPresent then
            I(g, "setForeground", 0xAAAAAA)
            I(g, "set", W - 10, 1, "slot:" .. (nActiveSlot == 0 and "a" or "b"))
        end
        I(g, "setForeground", 0xC0C0C0)
        I(g, "set", 2, 2, string.rep("=", W - 2))
    end
    local menuY = 4
    local timeout = tLoaderCfg.timeout or tConfig.nTimeout or 3
    if timeout < 0 then timeout = 0 end
    local deadline = computer.uptime() + timeout
    local running = true
    while running do
        for i, e in ipairs(entries) do
            local y = menuY + i - 1
            if g then
                if i == sel then I(g, "setBackground", 0xFFFFFF); I(g, "setForeground", 0)
                else I(g, "setBackground", 0); I(g, "setForeground", 0xC0C0C0) end
                local line = "  " .. e.title .. string.rep(" ", math.max(1, W - 4 - #e.title))
                I(g, "set", 2, y, line)
            end
        end
        if g then
            I(g, "setBackground", 0); I(g, "setForeground", 0xC0C0C0)
            I(g, "set", 2, H - 1, "Arrows:Select  Enter:Boot  DEL:Setup")
        end
        local ev, _, ch, code = computer.pullSignal(0.1)
        if ev == "key_down" then
            if code == 200 and sel > 1 then sel = sel - 1
            elseif code == 208 and sel < #entries then sel = sel + 1
            elseif code == 28 then running = false
            elseif code == 211 then _setup_requested = true; running = false end
        end
        if computer.uptime() >= deadline then running = false end
    end
end

-- =============================================
-- STEP 8: Find AXFS partition
-- =============================================
if not PO then
    p("ERROR: No AXFS partition found", 0xFF0000)
    goto enter_kbl_shell
end
p("AXFS @ sector " .. PO, 0xAAAAAA)

do
-- =============================================
-- STEP 9: Minimal AXFS v2 Reader
-- =============================================
local function axRs(n) return rs(PO + n) end
local sb = axRs(0)
if not sb or sb:sub(1, 4) ~= "AXF2" then sb = axRs(1) end
if not sb or sb:sub(1, 4) ~= "AXF2" then
    p("Bad AXFS superblock", 0xFF0000); goto enter_kbl_shell
end

local nDS = r16(sb, 20)
local nIT = r16(sb, 22)
local ips = math.floor(ss / 80)
local dpb = math.floor(ss / 32)

local function readInode(n)
    local sec = nIT + math.floor(n / ips)
    local off = (n % ips) * 80
    local sd = axRs(sec); if not sd then return nil end
    local o = off + 1
    local fl = sd:byte(o + 22); local ne = sd:byte(o + 23)
    local t = { iType = r16(sd, o), size = r32(sd, o + 8),
        flags = fl, nExtents = ne, extents = {},
        indirect = r16(sd, o + 76), inlineData = nil }
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

local function readBlk(n) return axRs(nDS + n) end
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

local function dirLookup(di, nm)
    for _, bn in ipairs(iBlocks(di)) do
        local sd = readBlk(bn)
        if sd then
            for i = 0, dpb - 1 do
                local o = i * 32 + 1; local ino = r16(sd, o)
                if ino > 0 then
                    local nl = sd:byte(o + 3)
                    if sd:sub(o + 4, o + 3 + nl) == nm then return ino end
                end
            end
        end
    end
end

local function resolve(path)
    local cur = 1
    for seg in path:gmatch("[^/]+") do
        local t = readInode(cur)
        if not t or t.iType ~= 2 then return nil end
        cur = dirLookup(t, seg)
        if not cur then return nil end
    end
    return cur
end

local function readFile(path)
    local n = resolve(path)
    if not n then return nil end
    local t = readInode(n)
    if not t or t.iType ~= 1 then return nil end
    if t.flags % 2 == 1 and t.inlineData then return t.inlineData:sub(1, t.size) end
    local ch = {}; local rem = t.size
    for _, bn in ipairs(iBlocks(t)) do
        local sd = readBlk(bn)
        if sd then ch[#ch + 1] = sd:sub(1, math.min(rem, ss)); rem = rem - ss end
        if rem <= 0 then break end
    end
    return table.concat(ch)
end

-- =============================================
-- STEP 10: BIOS SETUP
-- =============================================
if _setup_requested then
    p("Loading /boot/setup.lua...", 0xFFFF00)
    local sSetup = readFile("/boot/setup.lua")
    if sSetup then
        local setupEnv = {
            component = C, computer = computer, unicode = unicode,
            string = string, math = math, table = table, bit32 = bit32,
            pairs = pairs, ipairs = ipairs, type = type,
            tostring = tostring, tonumber = tonumber,
            pcall = pcall, error = error, load = load,
            setmetatable = setmetatable, select = select,
            _kbl_drive = D, _kbl_off = KO, _kbl_sz = _kbl_sz,
            _kbl_hdr = _kbl_hdr, _ss = ss, _readFile = readFile,
        }
        setupEnv._G = setupEnv
        local fn2, e2 = load(sSetup, "@setup", "t", setupEnv)
        if fn2 then
            pcall(fn2)
            _kbl_hdr = rs(KO)
            do
                local kh = _kbl_hdr
                local nLcStart = r16(kh, 27)
                local nLcCount = r16(kh, 29)
                local nLcSize  = r16(kh, 31)
                if nLcSize > 0 and nLcCount > 0 then
                    local tLc = {}
                    for i = 0, nLcCount - 1 do
                        tLc[#tLc + 1] = rs(KO + nLcStart + i) or ""
                    end
                    local sLc = table.concat(tLc):sub(1, nLcSize)
                    local fLc = load(sLc, "loader.cfg", "t", {})
                    if fLc then
                        local bOk, tR = pcall(fLc)
                        if bOk and type(tR) == "table" then tLoaderCfg = tR end
                    end
                end
            end
        else p("Setup error: " .. tostring(e2), 0xFF5555) end
    else
        p("/boot/setup.lua not found", 0xFF5555)
        computer.pullSignal(2)
    end
end

-- =============================================
-- STEP 11: Load kernel
-- =============================================
local entry = entries[sel] or entries[1]
if not entry then die("No boot entries") end

if g then
    I(g, "setBackground", 0); I(g, "setForeground", 0xFFFFFF)
    I(g, "fill", 1, 1, W, H, " ")
    local sBoot = "Booting: " .. (entry.title or "AxisOS")
    if bAbPresent then
        sBoot = sBoot .. " [slot:" .. (nActiveSlot == 0 and "a" or "b") .. "]"
    end
    I(g, "set", 1, 1, sBoot)
end
computer.beep(900, 0.2)

kc = readFile(entry.kernel or "/kernel.lua")
if not kc or #kc < 100 then
    p("Kernel missing or too small", 0xFF0000)
    -- Record kernel fail in KBL header
    do
        local sH = rs(KO)
        if sH and sH:sub(1, 4) == "AXKB" then
            local nFails = r32(sH, 73) + 1
            sH = sH:sub(1, 72) .. w32(nFails) .. sH:sub(77)
            I(D, "writeSector", KO + 1, sH)
        end
    end
    -- [A/B] Mark active slot as unverified
    if bAbPresent and BCO then
        if nActiveSlot == 0 then nSlotAState = 1 else nSlotBState = 1 end
        local sOld = rs(BCO) or ""
        local sUpd = "AXBC" .. string.char(1)
            .. string.char(nActiveSlot)
            .. string.char(nSlotAState)
            .. string.char(nSlotBState)
            .. w32(nAbBootAttempts)
        if #sOld >= #sUpd then sUpd = sUpd .. sOld:sub(#sUpd + 1) end
        I(D, "writeSector", BCO + 1, sUpd)
        p("A/B: Slot " .. (nActiveSlot == 0 and "a" or "b") ..
          " marked unverified (kernel missing)", 0xFFAA00)
    end
    goto enter_kbl_shell
end
if kc:sub(1, 3) == "\239\187\191" then kc = kc:sub(4) end

-- Build boot args from entry params
local ba = {
    lvl = "Info", safe = "Disabled", wait = "0",
    init = entry.init or "/bin/init.lua",
}
if entry.params then
    ba.lvl = entry.params.loglevel or ba.lvl
    if entry.params.safemode then ba.safe = "Enabled"; ba.safemode = "Enabled" end
    if entry.params.nodrivers then ba.nodrivers = true end
end

-- Execute kernel
p("Starting kernel...", 0x00FF00)
local ke = {
    raw_component = C, raw_computer = computer,
    boot_fs_address = _drive_addr,
    boot_args = ba,
    boot_fs_type = "axfs",
    boot_drive_addr = _drive_addr,
    boot_part_offset = PO,
    boot_part_size = PS,
    -- A/B boot info for kernel
    boot_slot        = nActiveSlot == 0 and "a" or "b",
    boot_slot_state  = nActiveSlot == 0 and nSlotAState or nSlotBState,
    boot_ab_present  = bAbPresent,
    boot_ab_attempts = nAbBootAttempts,
    boot_bc_offset   = BCO,
    boot_bc_size     = BCS,
}
setmetatable(ke, { __index = _G })
local fn, err = load(kc, "=kernel", "t", ke)
if not fn then
    p("PARSE: " .. tostring(err), 0xFF0000)
    bKernelCrashed = true
    -- Record kernel fail
    do
        local sH = rs(KO)
        if sH and sH:sub(1, 4) == "AXKB" then
            local nFails = r32(sH, 73) + 1
            sH = sH:sub(1, 72) .. w32(nFails) .. sH:sub(77)
            I(D, "writeSector", KO + 1, sH)
        end
    end
    -- [A/B] Mark slot unverified
    if bAbPresent and BCO then
        if nActiveSlot == 0 then nSlotAState = 1 else nSlotBState = 1 end
        local sOld = rs(BCO) or ""
        local sUpd = "AXBC" .. string.char(1)
            .. string.char(nActiveSlot)
            .. string.char(nSlotAState)
            .. string.char(nSlotBState)
            .. w32(nAbBootAttempts)
        if #sOld >= #sUpd then sUpd = sUpd .. sOld:sub(#sUpd + 1) end
        I(D, "writeSector", BCO + 1, sUpd)
        p("A/B: Slot " .. (nActiveSlot == 0 and "a" or "b") ..
          " marked unverified (parse error)", 0xFFAA00)
    end
    goto enter_kbl_shell
end

local ok, e2 = xpcall(fn, function(sErr) return tostring(sErr or "unknown error") end)
if not ok then
    p("PANIC: " .. tostring(e2):sub(1, W - 8), 0xFF0000)
    bKernelCrashed = true
    -- Record kernel fail
    do
        local sH = rs(KO)
        if sH and sH:sub(1, 4) == "AXKB" then
            local nFails = r32(sH, 73) + 1
            sH = sH:sub(1, 72) .. w32(nFails) .. sH:sub(77)
            I(D, "writeSector", KO + 1, sH)
        end
    end
    -- [A/B] Mark slot unverified
    if bAbPresent and BCO then
        if nActiveSlot == 0 then nSlotAState = 1 else nSlotBState = 1 end
        local sOld = rs(BCO) or ""
        local sUpd = "AXBC" .. string.char(1)
            .. string.char(nActiveSlot)
            .. string.char(nSlotAState)
            .. string.char(nSlotBState)
            .. w32(nAbBootAttempts)
        if #sOld >= #sUpd then sUpd = sUpd .. sOld:sub(#sUpd + 1) end
        I(D, "writeSector", BCO + 1, sUpd)
        p("A/B: Slot " .. (nActiveSlot == 0 and "a" or "b") ..
          " marked unverified (kernel panic)", 0xFFAA00)
    end
    goto enter_kbl_shell
end

-- Kernel returned normally (shouldn't happen)
die("Kernel exited")

end

-- =============================================
-- KBL SHELL ENTRY POINT
-- =============================================
::enter_kbl_shell::
do
    p("", 0x55FFFF)
    p("Entering KBL recovery shell...", 0x55FFFF)
    computer.beep(600, 0.1)

    local kh = _kbl_hdr
    local nShStart = r16(kh, 17)
    local nShCount = r16(kh, 19)
    local nShSize  = r16(kh, 21)

    if nShSize < 1 or nShCount < 1 then
        die("No KBL shell in partition")
    end

    local tSh = {}
    for i = 0, nShCount - 1 do
        tSh[#tSh + 1] = rs(KO + nShStart + i) or ""
    end
    local sShell = table.concat(tSh):sub(1, nShSize)

    local sReason = "unknown"
    if not KSO then sReason = "missing_ksr"
    elseif not PO then sReason = "no_axfs"
    elseif not kc or #(kc or "") < 100 then sReason = "kernel_fail"
    end

    local e = {
        _D = D, _K = KO, _P = PO, _R = sReason,
        component = C, computer = computer, bit32 = bit32,
        math = math, string = string, table = table, os = os,
        pairs = pairs, ipairs = ipairs, type = type,
        tostring = tostring, tonumber = tonumber,
        pcall = pcall, error = error, load = load,
        setmetatable = setmetatable, next = next,
        select = select, rawset = rawset, rawget = rawget,
    }
    setmetatable(e, { __index = _G }); e._G = e
    local f, le = load(sShell, "=kbl", "t", e)
    if not f then die("KBL parse: " .. tostring(le)) end
    local bOk, vR = pcall(f)
    if not bOk then
        p("KBL CRASH: " .. tostring(vR):sub(1, W - 2), 0xFF5555)
    end
    die("KBL shell exited")
end