--
-- /boot/boot_secure.lua
-- AxisOS SecureBoot EEPROM v1.0
-- Simplified bootloader with inline SecureBoot verification.
--
-- SecureBoot config lives in EEPROM DATA area (AXSB format):
--   1-4:   "AXSB" magic
--   5:     Mode (0=off, 1=warn, 2=enforce)
--   6-37:  Machine binding SHA256 (32 raw bytes)
--   38-69: Kernel hash SHA256 (32 raw bytes)
--
-- Enabling/disabling SecureBoot only writes the data area.
-- The EEPROM code never needs to be reflashed.
--
-- DEL  = Enter BIOS Setup (loaded from /boot/setup.lua)
-- Enter = Skip wait, boot immediately
--

local c, b = component, computer
local g, s
for f, t in c.list() do
    if t == "gpu" then g = c.proxy(f) end
    if t == "screen" then s = f end
end
if not g or not s then b.beep(1000, 0.2); error("NO GPU") end
g.bind(s)
local W, H = g.maxResolution()
g.setResolution(W, H)

local fs
for f in c.list("filesystem") do
    local p = c.proxy(f)
    if p.exists("/kernel.lua") then fs = p; break end
end
local dc; for f in c.list("data") do dc = c.proxy(f); break end
local eep; for f in c.list("eeprom") do eep = c.proxy(f); break end

local Z32 = string.rep("\0", 32)

local function halt(r)
    g.setBackground(0); g.fill(1, 1, W, H, " ")
    g.setForeground(0xFF0000); g.set(2, 2, "SECURE BOOT FAILURE")
    g.setForeground(0xFF5555); g.set(2, 4, tostring(r):sub(1, W - 4))
    g.setForeground(0xAAAAAA); g.set(2, 6, "System halted.")
    b.beep(200, 1)
    while true do b.pullSignal(math.huge) end
end

local function hex(d)
    local t = {}
    for i = 1, math.min(#d, 32) do t[i] = string.format("%02x", d:byte(i)) end
    return table.concat(t)
end

local function rf(p)
    if not fs then return nil end
    local h = fs.open(p, "r"); if not h then return nil end
    local t = {}
    while true do local s = fs.read(h, 4096); if not s then break end; t[#t + 1] = s end
    fs.close(h); return table.concat(t)
end

local function sbcfg()
    if not eep then return 0, Z32, Z32 end
    local d = eep.getData()
    if not d or #d < 69 or d:sub(1, 4) ~= "AXSB" then return 0, Z32, Z32 end
    return d:byte(5), d:sub(6, 37), d:sub(38, 69)
end

-- =============================================
-- SPLASH
-- =============================================

g.setBackground(0); g.setForeground(0xFFFFFF); g.fill(1, 1, W, H, " ")
g.set(1, 1, "AxisBIOS v0.5"); g.set(1, 2, "(C) 2025 Axis Corp")
b.beep(1100, 0.1)

local lo = {
    "Axis OS",
}
g.setForeground(0xC0C0C0)
local ly = math.floor(H / 3)
for i, l in ipairs(lo) do g.set(math.floor((W - #l) / 2), ly + i, l) end

local mode = sbcfg()
local ms = ({"OFF", "WARN", "ENFORCE"})[mode + 1] or "?"
g.setForeground(mode == 0 and 0x888888 or (mode == 1 and 0xFFFF00 or 0x55FF55))
g.set(2, H - 3, "SecureBoot: " .. ms)
g.setForeground(0xFFFFFF)
g.set(math.floor((W - 24) / 2), H - 1, "Press DEL to enter SETUP")

if not fs then halt("NO SYSTEM DISK") end

local dl = b.uptime() + 2
while b.uptime() < dl do
    local e, _, _, k = b.pullSignal(0.1)
    if e == "key_down" then
        if k == 211 then
            b.beep(1000, 0.1)
            local sc = rf("/boot/setup.lua")
            if sc then
                local env = {
                    component = c, computer = b, unicode = unicode,
                    string = string, math = math, table = table,
                    pairs = pairs, ipairs = ipairs, type = type,
                    tostring = tostring, tonumber = tonumber,
                    pcall = pcall, error = error, load = load,
                    setmetatable = setmetatable, next = next,
                }
                local f = load(sc, "@setup", "t", env)
                if f then pcall(f) end
            end
            break
        end
        if k == 28 then break end
    end
end

-- =============================================
-- SECUREBOOT VERIFICATION
-- =============================================

g.setBackground(0); g.fill(1, 1, W, H, " "); g.setForeground(0xFFFFFF)
local y = 1
local function p(t, col) g.setForeground(col or 0xFFFFFF); g.set(2, y, t); y = y + 1 end

p("AxisOS Boot", 0x00BCD4)

local bnd, kh
mode, bnd, kh = sbcfg()
local kcode

if mode > 0 and dc then
    p("SecureBoot: Verifying...", 0xAAAAAA)

    local ea = ""; for f in c.list("eeprom") do ea = f; break end
    local da = ""; for f in c.list("data") do da = f; break end
    local cb = dc.sha256(da .. ea .. fs.address)

    if bnd ~= Z32 then
        if bnd ~= cb then
            if mode >= 2 then halt("MACHINE BINDING MISMATCH\nExpected: " .. hex(bnd):sub(1,16) .. "\nGot:      " .. hex(cb):sub(1,16)) end
            p("WARN Binding mismatch", 0xFFFF00); b.beep(400, 0.2)
        else p("B_VERIF", 0x55FF55) end
    else p("BIND NOT_PROV", 0xFFAA00) end

    kcode = rf("/kernel.lua")
    if kcode and #kcode > 100 then
        local ck = dc.sha256(kcode)
        if kh ~= Z32 then
            if kh ~= ck then
                if mode >= 2 then halt("KERNEL HASH MISMATCH\nExpected: " .. hex(kh):sub(1,16) .. "\nGot:      " .. hex(ck):sub(1,16)) end
                p("WARN Kernel modified", 0xFFFF00); b.beep(400, 0.2)
            else p("Kern VERIFIED", 0x55FF55) end
        else p("KH NP", 0xFFAA00) end
    elseif mode >= 2 then halt("kern not found") end
elseif mode > 0 then
    p("SecureBoot: no data card", 0xFFAA00)
else
    p("SecureBoot: disabled", 0x888888)
end

-- =============================================
-- LOAD KERNEL
-- =============================================

if not kcode then kcode = rf("/kernel.lua") end
if not kcode or #kcode < 100 then halt("Kernel not found") end

local init = "/bin/init.lua"; local lvl = "Info"
local lc = rf("/boot/loader.cfg")
if lc then
    local f = load(lc, "loader.cfg", "t", {})
    if f then
        local ok, r = pcall(f)
        if ok and type(r) == "table" and r.entries then
            for _, e in ipairs(r.entries) do
                if e.id == (r.default or "axis") then
                    init = e.init or init
                    if e.params then lvl = e.params.loglevel or lvl end
                    break
                end
            end
        end
    end
end

if kcode:sub(1, 3) == "\239\187\191" then kcode = kcode:sub(4) end
p("Kernel: " .. #kcode .. " bytes", 0xAAAAAA)

local env = {
    raw_component = c, raw_computer = b,
    boot_fs_address = fs.address,
    boot_args = {lvl = lvl, safe = "Disabled", wait = "0", quick = "Disabled", init = init},
    boot_security = {mode = mode, verified = (mode > 0 and dc ~= nil)},
}
setmetatable(env, {__index = _G})
b.beep(900, 0.2)
local fn, err = load(kcode, "=kernel", "t", env)
if not fn then halt("PARSE: " .. tostring(err)) end
fn()