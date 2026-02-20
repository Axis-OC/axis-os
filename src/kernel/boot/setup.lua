--
-- /boot/setup.lua
-- AxisOS BIOS Setup Utility
-- Loaded from disk by EEPROM boot code when DEL is pressed.
-- No 4KB limit — this runs from the filesystem.
--
-- Features:
--   - Boot entry selection & editing
--   - Driver autoload configuration
--   - EEPROM parameter management
--   - SecureBoot enable/disable/provision
--

local a = component
local b = computer
local c = unicode

-- =============================================
-- GPU / SCREEN INIT
-- =============================================

local gpu, scr
for f, g in a.list() do
    if g == "gpu" then gpu = a.proxy(f) end
    if g == "screen" then scr = f end
end
if not gpu or not scr then return end
gpu.bind(scr)
local W, H = gpu.getResolution()

-- =============================================
-- EEPROM ACCESS
-- =============================================

local eep
for f in a.list("eeprom") do eep = a.proxy(f); break end

-- Data card (optional, for crypto)
local dataCard
for f in a.list("data") do dataCard = a.proxy(f); break end

-- Filesystem
local rootFs
for f in a.list("filesystem") do
    local p = a.proxy(f)
    if p.exists("/kernel.lua") then rootFs = p; break end
end

-- =============================================
-- EEPROM DATA AREA LAYOUT (256 bytes)
--
-- Bytes 0-3:    Magic "AXCF"
-- Byte 4:       SecureBoot mode (0=off, 1=warn, 2=enforce)
-- Byte 5:       Default boot entry index (0-based)
-- Byte 6:       Timeout (seconds, 0-15)
-- Byte 7:       Quick boot (0=normal, 1=quick)
-- Byte 8:       Log level (0=Debug..4=Error)
-- Byte 9:       Reserved
-- Bytes 10-11:  Checksum of bytes 4-9
-- Bytes 16-79:  Machine binding (64 hex chars)
-- Bytes 80-143: Kernel hash (64 hex chars)
-- Bytes 144-207: Manifest hash (64 hex chars)
-- Bytes 208-239: PK fingerprint (32 hex chars)
-- Bytes 240-243: Boot counter (uint32 BE)
-- Bytes 244-255: Reserved
-- =============================================

local EEPROM_MAGIC = "AXCF"

local function readEepromConfig()
    if not eep then return nil end
    local d = eep.getData()
    if not d or #d < 12 or d:sub(1, 4) ~= EEPROM_MAGIC then
        return {
            secureboot = 0,
            default_entry = 0,
            timeout = 3,
            quick = 0,
            loglevel = 2,
            machine_binding = "",
            kernel_hash = "",
            manifest_hash = "",
            pk_fingerprint = "",
            boot_count = 0,
        }
    end
    local function r32(s, o)
        return (s:byte(o) or 0) * 16777216 + (s:byte(o+1) or 0) * 65536 +
               (s:byte(o+2) or 0) * 256 + (s:byte(o+3) or 0)
    end
    local function rstr(s, o, n)
        local r = s:sub(o, o+n-1)
        local z = r:find("\0", 1, true)
        return z and r:sub(1, z-1) or r
    end
    return {
        secureboot = d:byte(5) or 0,
        default_entry = d:byte(6) or 0,
        timeout = d:byte(7) or 3,
        quick = d:byte(8) or 0,
        loglevel = d:byte(9) or 2,
        machine_binding = rstr(d, 17, 64),
        kernel_hash = rstr(d, 81, 64),
        manifest_hash = rstr(d, 145, 64),
        pk_fingerprint = rstr(d, 209, 32),
        boot_count = r32(d, 241),
    }
end

local function writeEepromConfig(cfg)
    if not eep then return false end
    local function w32(n)
        return string.char(
            math.floor(n / 16777216) % 256,
            math.floor(n / 65536) % 256,
            math.floor(n / 256) % 256,
            n % 256)
    end
    local function pad(s, n)
        if #s >= n then return s:sub(1, n) end
        return s .. string.rep("\0", n - #s)
    end

    local d = EEPROM_MAGIC                          -- 0-3
    d = d .. string.char(cfg.secureboot or 0)       -- 4
    d = d .. string.char(cfg.default_entry or 0)    -- 5
    d = d .. string.char(cfg.timeout or 3)          -- 6
    d = d .. string.char(cfg.quick or 0)            -- 7
    d = d .. string.char(cfg.loglevel or 2)         -- 8
    d = d .. "\0"                                   -- 9 reserved
    d = d .. "\0\0"                                 -- 10-11 checksum placeholder
    d = d .. "\0\0\0\0"                             -- 12-15 reserved
    d = d .. pad(cfg.machine_binding or "", 64)     -- 16-79
    d = d .. pad(cfg.kernel_hash or "", 64)         -- 80-143
    d = d .. pad(cfg.manifest_hash or "", 64)       -- 144-207
    d = d .. pad(cfg.pk_fingerprint or "", 32)      -- 208-239
    d = d .. w32(cfg.boot_count or 0)               -- 240-243
    d = d .. pad("", 12)                            -- 244-255

    -- Simple checksum of config bytes
    local ck = 0
    for i = 5, 10 do ck = (ck + d:byte(i)) % 65536 end
    d = d:sub(1, 10) .. string.char(math.floor(ck/256), ck%256) .. d:sub(13)

    eep.setData(d:sub(1, 256))
    return true
end

-- =============================================
-- LOADER.CFG READ/WRITE
-- =============================================

local function readLoaderCfg()
    if not rootFs then return nil end
    local h = rootFs.open("/boot/loader.cfg", "r")
    if not h then return nil end
    local chunks = {}
    while true do
        local s = rootFs.read(h, 4096)
        if not s then break end
        chunks[#chunks+1] = s
    end
    rootFs.close(h)
    local code = table.concat(chunks)
    local f = load(code, "loader.cfg", "t", {})
    if f then
        local ok, t = pcall(f)
        if ok and type(t) == "table" then return t end
    end
    return nil
end

local function writeLoaderCfg(cfg)
    if not rootFs then return false end
    local h = rootFs.open("/boot/loader.cfg", "w")
    if not h then return false end

    local function q(v)
        if type(v) == "string" then return '"' .. v:gsub('"', '\\"') .. '"' end
        if type(v) == "boolean" then return tostring(v) end
        if type(v) == "number" then return tostring(v) end
        return "nil"
    end

    rootFs.write(h, "-- /boot/loader.cfg (auto-generated by BIOS Setup)\n")
    rootFs.write(h, "return {\n")
    rootFs.write(h, "    timeout = " .. (cfg.timeout or 3) .. ",\n")
    rootFs.write(h, '    default = ' .. q(cfg.default or "axis") .. ',\n')
    rootFs.write(h, "    entries = {\n")
    for _, e in ipairs(cfg.entries or {}) do
        rootFs.write(h, "        {\n")
        rootFs.write(h, '            id = ' .. q(e.id) .. ',\n')
        rootFs.write(h, '            title = ' .. q(e.title) .. ',\n')
        rootFs.write(h, '            kernel = ' .. q(e.kernel) .. ',\n')
        rootFs.write(h, '            init = ' .. q(e.init) .. ',\n')
        rootFs.write(h, '            params = {\n')
        for k, v in pairs(e.params or {}) do
            rootFs.write(h, '                ' .. k .. ' = ' .. q(v) .. ',\n')
        end
        rootFs.write(h, '            },\n')
        rootFs.write(h, "        },\n")
    end
    rootFs.write(h, "    },\n")
    rootFs.write(h, '    drivers_cfg = ' .. q(cfg.drivers_cfg or "/boot/sys/drivers.cfg") .. ',\n')
    rootFs.write(h, "    secureboot = {\n")
    local sb = cfg.secureboot or {}
    rootFs.write(h, "        mode = " .. (sb.mode or 0) .. ",\n")
    rootFs.write(h, '        eeprom_template = ' .. q(sb.eeprom_template or "/boot/eeprom_template.lua") .. ',\n')
    rootFs.write(h, '        eeprom_plain = ' .. q(sb.eeprom_plain or "/boot/eeprom_axfs.lua") .. ',\n')
    rootFs.write(h, "        require_manifest = " .. tostring(sb.require_manifest or false) .. ",\n")
    rootFs.write(h, "        allow_offline = " .. tostring(sb.allow_offline ~= false) .. ",\n")
    rootFs.write(h, "    },\n")
    rootFs.write(h, "}\n")
    rootFs.close(h)
    return true
end

-- =============================================
-- UI DRAWING
-- =============================================

local BLUE    = 0x0000AA
local RED     = 0xAA0000
local YELLOW  = 0xFFFF00
local WHITE   = 0xFFFFFF
local GRAY    = 0xC0C0C0
local BLACK   = 0x000000
local CYAN    = 0x00AAAA
local GREEN   = 0x00AA00

local function cls(bg, fg)
    gpu.setBackground(bg or BLUE)
    gpu.setForeground(fg or GRAY)
    gpu.fill(1, 1, W, H, " ")
end

local function center(y, text, fg)
    if fg then gpu.setForeground(fg) end
    gpu.set(math.floor((W - c.len(text)) / 2), y, text)
end

local function box(x, y, w, h)
    local hor = string.rep("=", w - 2)
    gpu.set(x, y, "+" .. hor .. "+")
    gpu.set(x, y + h - 1, "+" .. hor .. "+")
    for i = 1, h - 2 do
        gpu.set(x, y + i, "|")
        gpu.set(x + w - 1, y + i, "|")
    end
end

local function pullKey()
    while true do
        local ev, _, ch, code = b.pullSignal()
        if ev == "key_down" then return ch, code end
    end
end

local function statusBar(text)
    gpu.setBackground(YELLOW)
    gpu.setForeground(BLACK)
    gpu.fill(1, H, W, 1, " ")
    gpu.set(2, H, text or "")
    gpu.setBackground(BLUE)
    gpu.setForeground(GRAY)
end

-- =============================================
-- MENU ENGINE
-- =============================================

local function drawMenu(title, items, sel, startY, maxH)
    startY = startY or 4
    maxH = maxH or (H - 6)
    local nVis = math.min(#items, maxH)

    -- Title
    gpu.setForeground(WHITE)
    gpu.set(4, startY - 1, " " .. title .. " ")
    gpu.setForeground(GRAY)

    for i = 1, nVis do
        local item = items[i]
        local y = startY + i - 1
        local label = item.label or item.l or tostring(item)
        local value = item.value or item.v or ""

        if type(value) == "boolean" then
            value = value and "[Enabled]" or "[Disabled]"
        end

        local padW = W - 8 - c.len(label) - c.len(tostring(value))
        if padW < 2 then padW = 2 end

        if i == sel then
            gpu.setBackground(RED)
            gpu.setForeground(WHITE)
        else
            gpu.setBackground(BLUE)
            gpu.setForeground(GRAY)
        end

        local line = " " .. label .. string.rep(" ", padW) .. tostring(value) .. " "
        if #line < W - 6 then line = line .. string.rep(" ", W - 6 - #line) end
        gpu.set(4, y, line)
    end

    gpu.setBackground(BLUE)
    gpu.setForeground(GRAY)
end

-- Generic menu loop. Returns selected index or nil on ESC.
local function menuLoop(title, items, statusText)
    local sel = 1
    while true do
        cls(BLUE, GRAY)
        center(1, "AXIS BIOS SETUP", WHITE)
        drawMenu(title, items, sel)
        statusBar(statusText or "Arrows:Select  Enter:Open  Esc:Back  F10:Save & Exit")

        local ch, code = pullKey()
        if code == 200 and sel > 1 then sel = sel - 1
        elseif code == 208 and sel < #items then sel = sel + 1
        elseif code == 28 then return sel, items[sel] -- Enter
        elseif code == 14 then return nil               -- bkcps
        elseif code == 68 then return -1               -- F10 = Save
        end
    end
end

-- =============================================
-- BOOT ENTRIES EDITOR
-- =============================================

local function editBootEntries(loaderCfg)
    local items = {}
    for i, e in ipairs(loaderCfg.entries or {}) do
        items[i] = {
            label = e.title,
            value = (e.id == loaderCfg.default) and "*DEFAULT*" or "",
        }
    end
    items[#items+1] = {label = "Set Default Entry", value = loaderCfg.default}
    items[#items+1] = {label = "Timeout (seconds)", value = tostring(loaderCfg.timeout)}

    while true do
        local idx = menuLoop("Boot Entries", items)
        if not idx then return end
        if idx == #items then
            -- Edit timeout
            loaderCfg.timeout = (loaderCfg.timeout + 1) % 11
            items[#items].value = tostring(loaderCfg.timeout)
        elseif idx == #items - 1 then
            -- Cycle default entry
            local entries = loaderCfg.entries or {}
            for i, e in ipairs(entries) do
                if e.id == loaderCfg.default then
                    local next = entries[(i % #entries) + 1]
                    loaderCfg.default = next.id
                    break
                end
            end
            -- Refresh
            for i, e in ipairs(entries) do
                items[i].value = (e.id == loaderCfg.default) and "*DEFAULT*" or ""
            end
            items[#items-1].value = loaderCfg.default
        end
    end
end

-- =============================================
-- DRIVER CONFIGURATION
-- =============================================

local function editDrivers(loaderCfg)
    -- Load drivers.cfg
    local drvPath = loaderCfg.drivers_cfg or "/boot/sys/drivers.cfg"
    local drivers = {}

    if rootFs then
        local h = rootFs.open(drvPath, "r")
        if h then
            local chunks = {}
            while true do
                local s = rootFs.read(h, 4096)
                if not s then break end
                chunks[#chunks+1] = s
            end
            rootFs.close(h)
            local f = load(table.concat(chunks), "drivers.cfg", "t", {})
            if f then
                local ok, t = pcall(f)
                if ok and type(t) == "table" then drivers = t end
            end
        end
    end

    while true do
        local items = {}
        for _, d in ipairs(drivers) do
            items[#items+1] = {
                label = d.name .. " (pri=" .. (d.priority or 500) .. ")",
                value = d.enabled ~= false and "[ON]" or "[OFF]",
                _ref = d,
            }
        end
        items[#items+1] = {label = "Driver Config Path", value = drvPath}

        local idx, item = menuLoop("Driver Autoload Configuration", items,
            "Enter:Toggle  Esc:Back")
        if not idx then return end

        if idx <= #drivers then
            -- Toggle driver enabled state
            local d = drivers[idx]
            d.enabled = not (d.enabled ~= false)
        end
    end
end

-- =============================================
-- EEPROM PARAMETERS
-- =============================================

local function editEepromParams()
    local cfg = readEepromConfig()

    local logLevels = {"Debug", "Info", "Warn", "Error", "None"}
    local sbModes = {"Disabled", "Warn Only", "Enforce"}

    while true do
        local items = {
            {label = "SecureBoot Mode",     value = sbModes[(cfg.secureboot or 0) + 1] or "?"},
            {label = "Default Boot Entry",  value = tostring(cfg.default_entry)},
            {label = "Timeout",             value = tostring(cfg.timeout) .. "s"},
            {label = "Quick Boot",          value = cfg.quick == 1 and "Enabled" or "Disabled"},
            {label = "Log Level",           value = logLevels[(cfg.loglevel or 2) + 1] or "?"},
            {label = "Boot Count",          value = tostring(cfg.boot_count), _readonly = true},
            {label = "", value = ""},
            {label = "Machine Binding",     value = cfg.machine_binding ~= "" and (cfg.machine_binding:sub(1,16) .. "...") or "(none)"},
            {label = "Kernel Hash",         value = cfg.kernel_hash ~= "" and (cfg.kernel_hash:sub(1,16) .. "...") or "(none)"},
            {label = "PK Fingerprint",      value = cfg.pk_fingerprint ~= "" and (cfg.pk_fingerprint:sub(1,16) .. "...") or "(none)"},
            {label = "", value = ""},
            {label = ">> Write to EEPROM",  value = ""},
            {label = ">> Reset EEPROM Data", value = ""},
        }

        local idx = menuLoop("EEPROM Parameters (NVRAM)", items,
            "Enter:Edit  Esc:Back  WARNING: Changes affect boot security!")
        if not idx then return end

        if idx == 1 then cfg.secureboot = (cfg.secureboot + 1) % 3
        elseif idx == 2 then cfg.default_entry = (cfg.default_entry + 1) % 5
        elseif idx == 3 then cfg.timeout = (cfg.timeout + 1) % 11
        elseif idx == 4 then cfg.quick = 1 - cfg.quick
        elseif idx == 5 then cfg.loglevel = (cfg.loglevel + 1) % 5
        elseif idx == 12 then
            -- Write
            if writeEepromConfig(cfg) then
                statusBar("EEPROM data written successfully!")
                b.pullSignal(1.5)
            end
        elseif idx == 13 then
            -- Reset
            cfg = {secureboot=0, default_entry=0, timeout=3, quick=0, loglevel=2,
                   machine_binding="", kernel_hash="", manifest_hash="",
                   pk_fingerprint="", boot_count=cfg.boot_count}
            writeEepromConfig(cfg)
            statusBar("EEPROM data reset to defaults!")
            b.pullSignal(1.5)
        end
    end
end

-- =============================================
-- SECUREBOOT SETUP
-- =============================================

local function hex(s)
    if not s then return "" end
    local t = {}
    for i = 1, math.min(#s, 32) do
        t[i] = string.format("%02x", s:byte(i))
    end
    return table.concat(t)
end

local function secureBootSetup(loaderCfg)
    local sb = loaderCfg.secureboot or {}
    local eepCfg = readEepromConfig()
    local hasDC = dataCard ~= nil
    local dcTier = 0
    if hasDC then
        if dataCard.ecdsa then dcTier = 3
        elseif dataCard.encrypt then dcTier = 2
        else dcTier = 1 end
    end

    -- Check for existing keys
    local hasPrivKey = rootFs and rootFs.exists("/etc/signing/private.key")
    local hasPubKey  = rootFs and rootFs.exists("/etc/signing/public.key")

    while true do
        local sModeStr = ({"Disabled","Warn","Enforce"})[eepCfg.secureboot + 1]
        local items = {
            {label = "Current Mode",       value = sModeStr},
            {label = "Data Card",          value = hasDC and ("Tier " .. dcTier) or "NOT FOUND"},
            {label = "Signing Keys",       value = (hasPrivKey and hasPubKey) and "Present" or "Missing"},
            {label = "Machine Binding",    value = eepCfg.machine_binding ~= "" and "Set" or "Not set"},
            {label = "Kernel Hash",        value = eepCfg.kernel_hash ~= "" and "Set" or "Not set"},
            {label = "", value = ""},
            {label = ">> Generate PKI Key Pair",    value = dcTier >= 3 and "" or "(Requires Tier 3)"},
            {label = ">> Compute Machine Binding",  value = hasDC and "" or "(Requires Data Card)"},
            {label = ">> Hash Current Kernel",      value = hasDC and "" or "(Requires Data Card)"},
            {label = "", value = ""},
            {label = ">> ENABLE SecureBoot",  value = "Flash secure EEPROM"},
            {label = ">> DISABLE SecureBoot", value = "Flash plain EEPROM"},
            {label = ">> Remove Keys & Attestation", value = "Clear all security data"},
        }

        local idx = menuLoop("SecureBoot Configuration", items,
            "Enter:Execute  Esc:Back  Data Card Tier 3 required for full PKI")
        if not idx then return end

        -- Generate Key Pair
        if idx == 7 and dcTier >= 3 then
            cls(BLACK, GREEN)
            center(H/2 - 2, "Generating ECDSA-384 Key Pair...", CYAN)
            center(H/2, "This may take a moment.", GRAY)

            local pub, priv = dataCard.generateKeyPair(384)
            if pub and priv then
                local pubB64 = dataCard.encode64(dataCard.serialize(pub))
                local privB64 = dataCard.encode64(dataCard.serialize(priv))

                -- Save keys
                rootFs.makeDirectory("/etc")
                rootFs.makeDirectory("/etc/signing")

                local hp = rootFs.open("/etc/signing/private.key", "w")
                if hp then rootFs.write(hp, privB64); rootFs.close(hp) end
                local hpub = rootFs.open("/etc/signing/public.key", "w")
                if hpub then rootFs.write(hpub, pubB64); rootFs.close(hpub) end

                -- Compute fingerprint
                local fp = hex(dataCard.sha256(pubB64))
                eepCfg.pk_fingerprint = fp:sub(1, 32)

                hasPrivKey = true; hasPubKey = true
                center(H/2 + 2, "Keys generated and saved to /etc/signing/", GREEN)
                center(H/2 + 3, "Fingerprint: " .. fp:sub(1, 32) .. "...", YELLOW)
            else
                center(H/2 + 2, "Key generation FAILED!", RED)
            end
            center(H/2 + 5, "Press any key...", GRAY)
            pullKey()
        end

        -- Compute Machine Binding
        if idx == 8 and hasDC then
            local eepAddr = ""
            for f in a.list("eeprom") do eepAddr = f; break end
            local dcAddr = ""
            for f in a.list("data") do dcAddr = f; break end
            local fsAddr = rootFs and rootFs.address or ""

            local binding = hex(dataCard.sha256(dcAddr .. eepAddr .. fsAddr))
            eepCfg.machine_binding = binding:sub(1, 64)
            writeEepromConfig(eepCfg)

            cls(BLACK, GREEN)
            center(H/2, "Machine binding computed and stored in EEPROM.", GREEN)
            center(H/2 + 1, binding:sub(1, 32) .. "...", CYAN)
            center(H/2 + 3, "Press any key...", GRAY)
            pullKey()
        end

        -- Hash Kernel
        if idx == 9 and hasDC then
            local kh = rootFs.open("/kernel.lua", "r")
            if kh then
                local chunks = {}
                while true do
                    local s = rootFs.read(kh, 8192)
                    if not s then break end
                    chunks[#chunks+1] = s
                end
                rootFs.close(kh)
                local hash = hex(dataCard.sha256(table.concat(chunks)))
                eepCfg.kernel_hash = hash:sub(1, 64)
                writeEepromConfig(eepCfg)

                cls(BLACK, GREEN)
                center(H/2, "Kernel hash computed and stored.", GREEN)
                center(H/2 + 1, hash:sub(1, 32) .. "...", CYAN)
                center(H/2 + 3, "Press any key...", GRAY)
            else
                cls(BLACK, RED)
                center(H/2, "/kernel.lua not found!", RED)
                center(H/2 + 2, "Press any key...", GRAY)
            end
            pullKey()
        end

        -- ENABLE SecureBoot
        if idx == 11 then
            cls(BLACK, RED)
            center(H/2 - 3, "=== ENABLE SECURE BOOT ===", RED)
            center(H/2 - 1, "This will flash the SecureBoot EEPROM template.", YELLOW)
            center(H/2,     "Machine binding and kernel hash will be embedded.", GRAY)
            center(H/2 + 2, "Type 'ENABLE' to confirm:", WHITE)

            -- Simple text input
            local input = ""
            local ix = math.floor(W/2) - 4
            while true do
                gpu.fill(ix, H/2 + 3, 20, 1, " ")
                gpu.set(ix, H/2 + 3, "> " .. input .. "_")
                local ch, code = pullKey()
                if code == 28 then break -- Enter
                elseif code == 1 then input = ""; break -- Esc
                elseif code == 14 and #input > 0 then input = input:sub(1, -2)
                elseif ch > 32 and ch < 127 then input = input .. string.char(ch) end
            end

            if input == "ENABLE" then
                -- Read template
                local tmpl = sb.eeprom_template or "/boot/eeprom_template.lua"
                local th = rootFs.open(tmpl, "r")
                if th then
                    local tc = {}
                    while true do
                        local s = rootFs.read(th, 4096)
                        if not s then break end
                        tc[#tc+1] = s
                    end
                    rootFs.close(th)
                    local code = table.concat(tc)

                    -- Substitute placeholders
                    code = code:gsub("%%%%PK_FP%%%%", eepCfg.pk_fingerprint or "")
                    code = code:gsub("%%%%KERN_H%%%%", eepCfg.kernel_hash or "")
                    code = code:gsub("%%%%MACH_B%%%%", eepCfg.machine_binding or "")
                    code = code:gsub("%%%%MANIF_H%%%%", eepCfg.manifest_hash or "")

                    if #code <= 4096 then
                        eep.set(code)
                        eep.setLabel("AxisOS SecureBoot")
                        eepCfg.secureboot = 2
                        writeEepromConfig(eepCfg)
                        sb.mode = 2
                        loaderCfg.secureboot = sb

                        cls(BLACK, GREEN)
                        center(H/2, "SecureBoot ENABLED. EEPROM flashed.", GREEN)
                        center(H/2 + 1, "Reboot to activate.", YELLOW)
                    else
                        cls(BLACK, RED)
                        center(H/2, "ERROR: Boot code too large (" .. #code .. "/4096)", RED)
                    end
                else
                    cls(BLACK, RED)
                    center(H/2, "Template not found: " .. tmpl, RED)
                end
                center(H/2 + 3, "Press any key...", GRAY)
                pullKey()
            end
        end

        -- DISABLE SecureBoot
        if idx == 12 then
            local plain = sb.eeprom_plain or "/boot/eeprom_axfs.lua"
            local ph = rootFs.open(plain, "r")
            if ph then
                local pc = {}
                while true do
                    local s = rootFs.read(ph, 4096)
                    if not s then break end
                    pc[#pc+1] = s
                end
                rootFs.close(ph)
                local code = table.concat(pc)
                if #code <= 4096 then
                    eep.set(code)
                    eep.setLabel("AxisOS Boot")
                    eepCfg.secureboot = 0
                    writeEepromConfig(eepCfg)
                    sb.mode = 0
                    loaderCfg.secureboot = sb

                    cls(BLACK, YELLOW)
                    center(H/2, "SecureBoot DISABLED. Plain EEPROM flashed.", YELLOW)
                else
                    cls(BLACK, RED)
                    center(H/2, "Plain boot code too large!", RED)
                end
            else
                cls(BLACK, RED)
                center(H/2, "Plain EEPROM not found: " .. plain, RED)
            end
            center(H/2 + 2, "Press any key...", GRAY)
            pullKey()
        end

        -- Remove Keys & Attestation
        if idx == 13 then
            cls(BLACK, RED)
            center(H/2 - 2, "!!! REMOVE ALL SECURITY DATA !!!", RED)
            center(H/2, "This will delete signing keys, clear EEPROM hashes,", YELLOW)
            center(H/2 + 1, "and disable SecureBoot.", YELLOW)
            center(H/2 + 3, "Type 'PURGE' to confirm:", WHITE)

            local input = ""
            local ix = math.floor(W/2) - 4
            while true do
                gpu.fill(ix, H/2 + 4, 20, 1, " ")
                gpu.set(ix, H/2 + 4, "> " .. input .. "_")
                local ch, code = pullKey()
                if code == 28 then break
                elseif code == 1 then input = ""; break
                elseif code == 14 and #input > 0 then input = input:sub(1, -2)
                elseif ch > 32 and ch < 127 then input = input .. string.char(ch) end
            end

            if input == "PURGE" then
                -- Delete keys
                pcall(function() rootFs.remove("/etc/signing/private.key") end)
                pcall(function() rootFs.remove("/etc/signing/public.key") end)
                pcall(function() rootFs.remove("/etc/machine.id") end)
                pcall(function() rootFs.remove("/boot/manifest.sig") end)

                -- Clear EEPROM security data
                eepCfg.machine_binding = ""
                eepCfg.kernel_hash = ""
                eepCfg.manifest_hash = ""
                eepCfg.pk_fingerprint = ""
                eepCfg.secureboot = 0
                writeEepromConfig(eepCfg)

                hasPrivKey = false; hasPubKey = false

                cls(BLACK, GREEN)
                center(H/2, "All security data purged.", GREEN)
                center(H/2 + 1, "SecureBoot disabled. Keys deleted.", YELLOW)
                center(H/2 + 3, "Press any key...", GRAY)
                pullKey()
            end
        end
    end
end

-- =============================================
-- MAIN MENU
-- =============================================

local function mainMenu()
    local loaderCfg = readLoaderCfg() or {
        timeout = 3, default = "axis", entries = {},
        drivers_cfg = "/boot/sys/drivers.cfg",
        secureboot = {mode = 0},
    }

    while true do
        local items = {
            {label = "> Boot Entries",            value = tostring(#(loaderCfg.entries or {})) .. " entries"},
            {label = "> Driver Configuration",    value = loaderCfg.drivers_cfg or ""},
            {label = "> EEPROM Parameters",       value = "NVRAM Settings"},
            {label = "> SecureBoot & PKI",         value = ({"Off","Warn","Enforce"})[(loaderCfg.secureboot or {}).mode + 1] or "?"},
            {label = "", value = ""},
            {label = "Save & Exit",               value = "Write loader.cfg"},
            {label = "Exit Without Saving",       value = ""},
            {label = "Reboot",                    value = ""},
        }

        local idx = menuLoop("AXIS BIOS SETUP", items,
            "BKSP:Quit  Arrows:Select  Enter:Open  F10:Save")

        if not idx or idx == 7 then return false   -- Exit without saving
        elseif idx == -1 or idx == 6 then
            writeLoaderCfg(loaderCfg)
            statusBar("Configuration saved!")
            b.pullSignal(1)
            return true
        elseif idx == 8 then b.shutdown(true)       -- Reboot
        elseif idx == 1 then editBootEntries(loaderCfg)
        elseif idx == 2 then editDrivers(loaderCfg)
        elseif idx == 3 then editEepromParams()
        elseif idx == 4 then secureBootSetup(loaderCfg)
        end
    end
end

-- Run
mainMenu()