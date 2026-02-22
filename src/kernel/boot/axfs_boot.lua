--
-- /boot/axfs_boot.lua
-- AxisOS AXFS v2 Boot EEPROM (General — No SecureBoot)
-- Reads Amiga RDB partition table, finds AXFS v2 partition, boots kernel.
-- Must be minified to fit in 4KB EEPROM.
--
local c, p = component, computer

-- Discover GPU + Screen
local g, s
for a, t in c.list() do
    local x = c.proxy(a)
    if t == "gpu" and not g then g = x
    elseif t == "screen" and not s then s = a end
end
if not (g and s) then p.beep(1000, .2); error("NO GPU") end
g.bind(s)
local W, H = g.maxResolution()
g.setResolution(W, H)
g.setBackground(0)
g.setForeground(0xFFFFFF)
g.fill(1, 1, W, H, " ")

-- Binary helpers (big-endian)
local function h(d, o) return d:byte(o) * 256 + d:byte(o + 1) end
local function w(d, o)
    return d:byte(o) * 16777216 + d:byte(o + 1) * 65536
         + d:byte(o + 2) * 256 + d:byte(o + 3)
end
local function iw(d, o)
    local u = w(d, o)
    if u >= 2147483648 then return u - 4294967296 end
    return u
end

local function halt(m)
    g.setForeground(0xFF0000)
    g.set(2, H - 1, tostring(m):sub(1, W - 4))
    p.beep(200, 1)
    while true do p.pullSignal(math.huge) end
end

g.set(1, 1, "AxisOS AXFS Boot")

-- Find drive with Amiga RDB
local D, A
for a in c.list("drive") do
    local d = c.proxy(a)
    local z = d.readSector(1)  -- OC sectors are 1-indexed
    if z and #z >= 4 and z:sub(1, 4) == "RDSK" then
        D = d; A = a; break
    end
end
if not D then halt("No RDB drive") end

local ss = D.getSectorSize()

-- Parse RDB header, get PartitionList pointer
local z = D.readSector(1)
local pl = iw(z, 25)  -- signed: -1 = no partitions
if pl < 0 then halt("No partitions") end

-- Walk partition linked list, find first AXFS v2 partition
local PO, PS  -- partition offset (sectors), partition size (sectors)
local ns = pl
for _ = 1, 16 do
    if ns < 0 then break end
    local q = D.readSector(ns + 1)
    if not q or q:sub(1, 4) ~= "PART" then break end
    if w(q, 65) == 0x41584632 then  -- FsType == "AXF2"
        PO = w(q, 57)  -- StartSector
        PS = w(q, 61)  -- SizeSectors
        break
    end
    ns = iw(q, 17)  -- Next (signed)
end
if not PO then halt("No AXFS partition") end

-- Partition-relative sector read
local function pr(n) return D.readSector(PO + n + 1) end

-- Read & verify AXFS v2 superblock
local sb = pr(0)
if not sb or sb:sub(1, 4) ~= "AXF2" then
    sb = pr(1)  -- try mirror superblock
end
if not sb or sb:sub(1, 4) ~= "AXF2" then halt("Bad AXFS") end

local ds = h(sb, 20)  -- dataStart sector
local it = h(sb, 22)  -- itableStart sector
local ip = math.floor(ss / 80)  -- inodes per sector (v2: 80-byte inodes)
local dp = math.floor(ss / 32)  -- directory entries per block

-- Read inode by number (AXFS v2: 80 bytes, extent-based)
local function ri(n)
    local sc = it + math.floor(n / ip)
    local of = (n % ip) * 80
    local sd = pr(sc)
    if not sd then return nil end
    local o = of + 1
    local fl = sd:byte(o + 22)  -- flags (bit 0 = F_INLINE)
    local ne = sd:byte(o + 23)  -- nExtents
    local t = {
        T = h(sd, o),           -- iType
        S = w(sd, o + 8),       -- size
        F = fl, N = ne,
        E = {},                 -- extents
        I = h(sd, o + 76),     -- indirect block
        D = nil                 -- inline data
    }
    if fl % 2 == 1 then  -- F_INLINE: data stored in inode
        t.D = sd:sub(o + 24, o + 24 + math.min(t.S, 52) - 1)
    else  -- Extent-based: up to 13 extents of (start, count)
        for i = 1, math.min(ne, 13) do
            local eo = o + 24 + (i - 1) * 4
            t.E[i] = {h(sd, eo), h(sd, eo + 2)}
        end
    end
    return t
end

-- Get flat list of data block numbers from inode
local function ib(t)
    if t.F % 2 == 1 then return {} end  -- inline, no blocks
    local r = {}
    for i = 1, math.min(t.N, 13) do
        local e = t.E[i]
        if e and (e[1] > 0 or e[2] > 0) then
            for j = 0, e[2] - 1 do r[#r + 1] = e[1] + j end
        end
    end
    -- Indirect extents (overflow beyond 13)
    if t.N > 13 and t.I > 0 then
        local si = pr(ds + t.I)
        if si then
            local pp = math.floor(ss / 4)
            for i = 1, pp do
                local eS = h(si, (i - 1) * 4 + 1)
                local eC = h(si, (i - 1) * 4 + 3)
                if eC > 0 then
                    for j = 0, eC - 1 do r[#r + 1] = eS + j end
                end
            end
        end
    end
    return r
end

-- Read data block by number
local function rb(n) return pr(ds + n) end

-- Look up filename in a directory inode
local function dl(di, nm)
    for _, bn in ipairs(ib(di)) do
        local sd = rb(bn)
        if sd then
            for i = 0, dp - 1 do
                local o = i * 32 + 1
                local ino = h(sd, o)
                if ino > 0 then
                    local nl = sd:byte(o + 3)
                    if sd:sub(o + 4, o + 3 + nl) == nm then return ino end
                end
            end
        end
    end
end

-- Resolve path string to inode number
local function rv(pa)
    local cu = 1  -- root inode
    for seg in pa:gmatch("[^/]+") do
        local t = ri(cu)
        if not t or t.T ~= 2 then return nil end  -- not a directory
        cu = dl(t, seg)
        if not cu then return nil end
    end
    return cu
end

-- Read entire file by path
local function rf(pa)
    local n = rv(pa)
    if not n then return nil end
    local t = ri(n)
    if not t or t.T ~= 1 then return nil end  -- not a file
    -- Inline data?
    if t.F % 2 == 1 and t.D then return t.D:sub(1, t.S) end
    -- Extent-based read
    local ch = {}
    local rem = t.S
    for _, bn in ipairs(ib(t)) do
        local sd = rb(bn)
        if sd then
            ch[#ch + 1] = sd:sub(1, math.min(rem, ss))
            rem = rem - ss
        end
        if rem <= 0 then break end
    end
    return table.concat(ch)
end

-- Boot
g.set(1, 2, "Booting...")
p.beep(900, .2)

local kc = rf("/kernel.lua")
if not kc or #kc < 100 then halt("Kernel missing") end
if kc:sub(1, 3) == "\239\187\191" then kc = kc:sub(4) end

-- Parse loader.cfg for boot parameters
local ba = {lvl = "Info", safe = "Disabled", wait = "0", init = "/bin/init.lua"}
pcall(function()
    local lc = rf("/boot/loader.cfg")
    if lc then
        local cfg = load(lc, "l", "t", {})()
        for _, en in ipairs(cfg.entries) do
            if en.id == (cfg.default or "axis") then
                ba.init = en.init or ba.init
                if en.params then
                    ba.lvl = en.params.loglevel or ba.lvl
                    if en.params.safemode then ba.safe = "Enabled" end
                end
                break
            end
        end
    end
end)

-- Execute kernel with AXFS boot context
local ke = {
    raw_component = c, raw_computer = p,
    boot_fs_address = A, boot_args = ba,
    boot_fs_type = "axfs",
    boot_drive_addr = A,
    boot_part_offset = PO,
    boot_part_size = PS,
}
setmetatable(ke, {__index = _G})
local fn, err = load(kc, "=kernel", "t", ke)
if not fn then halt("PARSE:" .. tostring(err)) end
local ok, e2 = xpcall(fn, debug.traceback)
if not ok then halt("PANIC:" .. tostring(e2)) end