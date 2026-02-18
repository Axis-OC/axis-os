--
-- installer.lua
--
local component = require("component")
local event = require("event")
local term = require("term")
local fs = require("filesystem")
local computer = require("computer")
local unicode = require("unicode")
local gpu = component.gpu
local internet = component.internet

local data_card = component.isAvailable("data") and component.data or nil

-- === CONFIGURATION ===
local RAW_ROOT = "https://repo.axis-os.ru"

-- MANIFEST (Relative paths inside version folder)
local CORE_MANIFEST = {
    "kernel.lua",
    "bin/init.lua",
    "bin/sh.lua",
    "lib/filesystem.lua",
    "lib/pipeline_manager.lua",
    "lib/syscall.lua",
    "lib/errcheck.lua",
    "lib/ob_manager.lua",
    "lib/thread.lua",
    "drivers/tty.sys.lua",
    "drivers/screen.sys.lua",
    "drivers/ringfs.sys.lua",
    "drivers/keyboard.sys.lua",
    "drivers/internet.sys.lua",
    "drivers/gpu.sys.lua",
    "drivers/filesystem.sys.lua",
    "drivers/eeprom.sys.lua",
    "drivers/computer.sys.lua",
    "system/dkms.lua",
    "system/driverdispatch.lua",
    "system/driverhost.lua",
    "system/lib/dk/shared_structs.lua",
    "system/lib/dk/kmd_api.lua",
    "system/lib/dk/umd_api.lua",
    "system/lib/dk/common_api.lua",
    "system/lib/dk/spinlock.lua",
    "sys/security/dkms_sec.lua",
    "usr/commands/cat.lua",
    "usr/commands/chmod.lua",
    "usr/commands/clear.lua",
    "usr/commands/echo.lua",
    "usr/commands/insmod.lua",
    "usr/commands/logread.lua",
    "usr/commands/ls.lua",
    "usr/commands/pkgman.lua",
    "usr/commands/reboot.lua",
    "usr/commands/shutdown.lua",
    "usr/commands/su.lua",
    "usr/commands/wget.lua",
    "etc/perms.lua",
    "etc/autoload.lua",
    "etc/sys.cfg"
}

-- === COLORS ===
local C_BG       = 0x050505 
local C_PANEL    = 0x111111 
local C_TEXT     = 0xE0E0E0 
local C_ACCENT   = 0x00BCD4 
local C_ACCENT_T = 0x000000 
local C_DIM      = 0x555555 
local C_ERR      = 0xFF5555 
local C_WARN     = 0xFF9E42 
local C_SUCCESS  = 0x55FF55
local C_HEADER   = 0x002228 

local C_ORIGINAL_BG, C_ORIGINAL_FG = gpu.getBackground(), gpu.getForeground()

local B = { H="─", V="│", TL="┌", TR="┐", BL="└", BR="┘" }

if not internet then error("Internet Card required.") end
local W, H = gpu.getResolution()

-- === UTILS ===

local function get_parent_dir(path)
    return path:match("^(.*)/") or ""
end

local function http_get(url)
    local max_retries = 3
    local last_err = ""
    
    for attempt = 1, max_retries do
        local headers = {
            ["User-Agent"] = "AxisOS-Installer/0.4",
            ["Connection"] = "keep-alive",
            ["Accept-Encoding"] = "identity"
        }
        
        local handle, reason = internet.request(url, nil, headers)
        
        if not handle then
            last_err = "Net Fail: " .. tostring(reason)
        else
            local iters = 0
            while not handle.finishConnect() and iters < 50 do
                os.sleep(0.05)
                iters = iters + 1
            end
            
            local code, msg = handle.response()
            if code and code ~= 200 then
                handle.close()
                last_err = "HTTP " .. tostring(code)
            else
                local buffer = {}
                while true do
                    local chunk, rerr = handle.read(math.huge)
                    if chunk and #chunk > 0 then
                        table.insert(buffer, chunk)
                    elseif not chunk then
                        break
                    end
                end
                handle.close()
                
                local data = table.concat(buffer)
                
                if #data == 0 then
                    last_err = "Empty Response"
                elseif data:match("<!DOCTYPE html>") or data:match("<html") then
                    last_err = "Cloudflare Block (HTML)"
                else
                    if data:byte(1) == 31 and data:byte(2) == 139 then
                        if data_card then
                            local status, inflated = pcall(data_card.inflate, data)
                            if status then return inflated else last_err = "GZIP Inflate Fail" end
                        else
                            last_err = "GZIP recvd w/o DataCard"
                        end
                    else
                        return data
                    end
                end
            end
        end
        if attempt < max_retries then os.sleep(0.2) end
    end
    
    return nil, last_err
end

local function clear()
    gpu.setBackground(C_BG); gpu.setForeground(C_TEXT); gpu.fill(1, 1, W, H, " ")
end

local function center_text(y, text, color)
    gpu.setForeground(color or C_TEXT)
    gpu.set(math.floor((W - unicode.len(text))/2), y, text)
end

local function draw_box(x, y, w, h, title, color_border, bg_override)
    gpu.setBackground(bg_override or C_BG)
    gpu.setForeground(color_border or C_DIM)
    local t_str = title and (" " .. title .. " ") or ""
    gpu.set(x, y, B.TL .. B.H .. t_str .. string.rep(B.H, w - unicode.len(t_str) - 4) .. B.TR)
    for i=1, h-2 do
        gpu.set(x, y+i, B.V); gpu.set(x+w-1, y+i, B.V)
    end
    gpu.set(x, y+h-1, B.BL .. string.rep(B.H, w-2) .. B.BR)
    gpu.setForeground(C_TEXT)
end

local function draw_header(subtitle)
    gpu.setBackground(C_HEADER); gpu.setForeground(C_ACCENT)
    gpu.fill(1, 1, W, 1, " ")
    gpu.set(2, 1, "Axis OS Installer" .. (subtitle and (" :: " .. subtitle) or ""))
    local time = os.date("%H:%M"); gpu.set(W - #time - 1, 1, time)
    gpu.setBackground(C_BG)
end

local function status_bar(text)
    gpu.setBackground(C_PANEL); gpu.setForeground(C_TEXT)
    gpu.fill(1, H, W, 1, " ")
    gpu.set(2, H, text); gpu.setBackground(C_BG)
end

local function confirm_dialog(msg)
    local bw, bh = #msg + 8, 5
    local bx, by = math.floor((W-bw)/2), math.floor((H-bh)/2)
    gpu.fill(bx, by, bw, bh, " ")
    draw_box(bx, by, bw, bh, "CONFIRM", C_WARN)
    center_text(by+1, msg, C_TEXT)
    center_text(by+3, "[Y]es   [N]o", C_ACCENT)
    while true do
        local _, _, _, code = event.pull("key_down")
        if code == 21 then return true  -- Y
        elseif code == 49 then return false -- N
        end
    end
end

local function input_box(title, default, is_pass)
    local bw, bh = 50, 3
    local bx, by = math.floor((W-bw)/2), math.floor((H-bh)/2)
    gpu.fill(bx, by, bw, bh, " ")
    draw_box(bx, by, bw, bh, title, C_ACCENT)
    local val = default or ""
    while true do
        local view = is_pass and string.rep("*", #val) or val
        gpu.set(bx+2, by+1, view .. "_   ")
        local _, _, ch, code = event.pull("key_down")
        if code == 28 then return val -- Enter
        elseif code == 1 then return nil -- Esc
        elseif code == 14 then val = unicode.sub(val, 1, -2)
        elseif ch > 0 and not require("keyboard").isControl(ch) then val = val .. unicode.char(ch) end
    end
end

local function dropdown_menu(x, y, options)
    local w = 20
    for _, o in ipairs(options) do w = math.max(w, #o + 4) end
    local h = #options + 2
    if x + w > W then x = W - w - 1 end
    if y + h > H then y = H - h - 1 end

    local sel = 1
    while true do
        gpu.setBackground(C_PANEL)
        gpu.fill(x, y, w, h, " ")
        gpu.setForeground(C_ACCENT)
        gpu.set(x, y, B.TL .. string.rep(B.H, w-2) .. B.TR)
        for i=1, #options do
            gpu.set(x, y+i, B.V); gpu.set(x+w-1, y+i, B.V)
            if i == sel then
                gpu.setBackground(C_ACCENT); gpu.setForeground(C_ACCENT_T)
            else
                gpu.setBackground(C_PANEL); gpu.setForeground(C_TEXT)
            end
            local txt = options[i]
            gpu.set(x+1, y+i, " " .. txt .. string.rep(" ", w - #txt - 3))
        end
        gpu.setBackground(C_PANEL); gpu.setForeground(C_ACCENT)
        gpu.set(x, y+h-1, B.BL .. string.rep(B.H, w-2) .. B.BR)
        
        local _, _, _, code = event.pull("key_down")
        if code == 200 then sel = sel > 1 and sel - 1 or #options
        elseif code == 208 then sel = sel < #options and sel + 1 or 1
        elseif code == 28 then gpu.setBackground(C_BG); return options[sel] 
        elseif code == 1 then gpu.setBackground(C_BG); return nil end
    end
end

local function draw_prog(pct, msg)
    local bw = W - 20
    local bx, by = 10, math.floor(H/2)
    gpu.fill(bx, by-1, bw, 4, " ")
    gpu.setForeground(C_TEXT)
    gpu.set(bx, by-1, msg)
    gpu.setBackground(C_PANEL); gpu.fill(bx, by+1, bw, 1, " ")
    gpu.setBackground(C_ACCENT); gpu.fill(bx, by+1, math.floor(pct*bw), 1, " ")
    gpu.setBackground(C_BG)
end

local function format_size(n)
    if not n then return "0B" end
    if n >= 10^9 then return string.format("%.1fG", n/10^9)
    elseif n >= 10^6 then return string.format("%.1fM", n/10^6)
    elseif n >= 10^3 then return string.format("%.1fK", n/10^3)
    else return string.format("%dB", math.floor(n)) end
end

-- === GLOBAL STATE ===
local State = {
    Hostname = "axis-node",
    RootPass = "toor",
    Users = {},
    Mounts = {},
    Packages = {},
    RepoCache = {} 
}

-- === DASHBOARD ===
local function draw_dashboard()
    local col_w = 32
    local lx, ly = 3, 3
    
    gpu.setForeground(C_ACCENT)
    gpu.set(lx, ly+0, "   [ + ]   Axis OS")
    gpu.set(lx, ly+1, "   | | |   v0.3")
    gpu.set(lx, ly+2, "   [___]   Xen XK Arch")
    
    ly = ly + 4
    draw_box(lx, ly, col_w, 10, "HARDWARE PROBE", C_DIM)
    
    local hw_y = ly + 1
    local function print_hw(label, val)
        gpu.set(lx+2, hw_y, label .. ":")
        gpu.set(lx+12, hw_y, val)
        hw_y = hw_y + 1
    end
    
    gpu.setForeground(C_TEXT)
    print_hw("CPU", component.isAvailable("cpu") and "Zilog Z80" or "Unknown")
    local total_ram = computer.totalMemory()
    print_hw("Memory", format_size(total_ram))
    print_hw("Display", W .. "x" .. H)
    print_hw("Network", internet and "Online" or "Offline")
    
    if not data_card then
        gpu.setForeground(C_ERR)
        gpu.set(lx+2, hw_y+1, "! NO DATA CARD !")
        gpu.set(lx+2, hw_y+2, "GZIP Fix Disabled")
    end
    
    ly = ly + 11
    gpu.setForeground(C_DIM)
    gpu.set(lx, ly, "Navigation:")
    gpu.set(lx, ly+1, string.rep(B.H, 20))
    gpu.setForeground(C_TEXT)
    gpu.set(lx, ly+2, "\24 \25 Arrows : Move")
    gpu.set(lx, ly+3, "ENTER      : Select")
end

-- === PARTITION MANAGER ===
local function scan_drives()
    local drives = {}
    local tmp = computer.tmpAddress()
    for addr in component.list("filesystem") do
        local p = component.proxy(addr)
        if addr ~= tmp and p.getLabel() ~= "tmpfs" then
            table.insert(drives, {
                uuid = addr,
                label = p.getLabel() or "HDD",
                total_size = p.spaceTotal(),
                ro = p.isReadOnly()
            })
        end
    end
    table.insert(drives, { uuid = "virtual", label = "VIRTUAL (RAM)", total_size = 0, ro = false })
    return drives
end

local function size_selector(max_size, current_size)
    if max_size == 0 then return 0 end 
    local size = current_size or math.floor(max_size / 2)
    local bw, bh = 60, 6
    local bx, by = math.floor((W-bw)/2), math.floor((H-bh)/2)
    
    while true do
        gpu.fill(bx, by, bw, bh, " ")
        draw_box(bx, by, bw, bh, "PARTITION SIZE", C_ACCENT)
        local pct = size / max_size
        local bar_w = bw - 4
        local fill = math.floor(pct * bar_w)
        gpu.set(bx+2, by+1, string.format("Size: %s / %s (%.1f%%)", format_size(size), format_size(max_size), pct*100))
        gpu.setBackground(C_DIM); gpu.fill(bx+2, by+3, bar_w, 1, " ")
        gpu.setBackground(C_ACCENT); gpu.fill(bx+2, by+3, fill, 1, " "); gpu.setBackground(C_BG)
        gpu.set(bx+2, by+5, "LEFT/RIGHT: Adjust | ENTER: Confirm")
        local _, _, _, code = event.pull("key_down")
        local step = math.floor(max_size / 100) 
        if code == 203 then size = math.max(1024, size - step) 
        elseif code == 205 then size = math.min(max_size, size + step) 
        elseif code == 28 then return size
        elseif code == 1 then return nil end
    end
end

local function auto_partition_drive(drive)
    local bw, bh = 40, 8
    local bx, by = math.floor((W-bw)/2), math.floor((H-bh)/2)
    gpu.fill(bx, by, bw, bh, " ")
    draw_box(bx, by, bw, bh, "AUTO PARTITIONING", C_ACCENT)
    gpu.set(bx+2, by+2, "Calculating optimal layout...")
    
    local new_mounts = {}
    for _, m in ipairs(State.Mounts) do if m.uuid ~= drive.uuid then table.insert(new_mounts, m) end end
    State.Mounts = new_mounts
    
    os.sleep(0.5)
    
    local total = drive.total_size
    local swap_sz = 1024 * 1024 
    local log_sz  = 3000        
    local home_sz = 209715      
    
    if total < 2 * 1024 * 1024 then
         swap_sz = math.floor(total * 0.1)
         home_sz = math.floor(total * 0.2)
    end
    
    if total < 512 * 1024 then
         table.insert(State.Mounts, { 
             uuid = drive.uuid, mount = "/", type = "rootfs", path = "/",
             options = "rw", size_limit = 0, label = drive.label 
         })
         gpu.set(bx+2, by+4, "Layout: Single Root Partition")
    else
         table.insert(State.Mounts, { 
             uuid = drive.uuid, mount = "/", type = "rootfs", path = "/",
             options = "rw", size_limit = 0, label = drive.label 
         })
         table.insert(State.Mounts, { 
             uuid = drive.uuid, mount = "/home", type = "homefs", path = "/home",
             options = "rw", size_limit = home_sz, label = drive.label 
         })
         table.insert(State.Mounts, { 
             uuid = drive.uuid, mount = "none", type = "swap", path = "/swapfile",
             options = "rw", size_limit = swap_sz, label = drive.label 
         })
         table.insert(State.Mounts, { 
             uuid = drive.uuid, mount = "/var/log", type = "ringfs", path = "/log",
             options = "rw", size_limit = log_sz, label = drive.label 
         })
         gpu.set(bx+2, by+4, "Layout: Root, Home, Swap, Log")
    end
    
    for i=1, 20 do
        local p = i/20
        gpu.setBackground(C_DIM); gpu.fill(bx+2, by+6, bw-4, 1, " ")
        gpu.setBackground(C_SUCCESS); gpu.fill(bx+2, by+6, math.ceil((bw-4)*p), 1, " ")
        gpu.setBackground(C_BG)
        os.sleep(0.05)
    end
    os.sleep(0.5)
end

local function manage_drive_partitions(drive)
    local selected = 1
    local function next_type(curr)
        if curr == "rootfs" then return "homefs"
        elseif curr == "homefs" then return "ringfs"
        elseif curr == "ringfs" then return "swap"
        else return "rootfs" end
    end

    while true do
        local drive_mounts = {}
        local used_space = 0
        for i, m in ipairs(State.Mounts) do
            if m.uuid == drive.uuid then 
                table.insert(drive_mounts, {data=m, idx=i}) 
                used_space = used_space + (m.size_limit or 0)
            end
        end
        local free_space = drive.total_size - used_space
        
        clear()
        draw_header("Editing: " .. drive.label)
        gpu.setForeground(C_ACCENT)
        gpu.set(2, 3, "DISK UUID: " .. drive.uuid:sub(1,8))
        gpu.set(2, 4, string.format("CAPACITY : %s Total | %s Free", format_size(drive.total_size), format_size(free_space)))
        gpu.setForeground(C_DIM)
        gpu.set(2, 6, " ID   MOUNT POINT     TYPE          OPTS")
        gpu.set(2, 7, string.rep(B.H, W-4))
        
        local row_y = 8
        for i, entry in ipairs(drive_mounts) do
            if i == selected then gpu.setBackground(C_ACCENT); gpu.setForeground(C_ACCENT_T)
            else gpu.setBackground(C_BG); gpu.setForeground(C_TEXT) end
            local m = entry.data
            local size_str = (m.type == "rootfs") and "AUTO" or ("sz="..format_size(m.size_limit))
            local line = string.format(" %-4d %-15s %-13s %-20s", i, m.mount, "<"..m.type..">", size_str)
            gpu.set(2, row_y, line .. string.rep(" ", W - #line - 2))
            row_y = row_y + 1
        end
        gpu.setBackground(C_BG)
        gpu.setForeground(C_ACCENT)
        gpu.set(2, row_y + 2, "[A]dd   [D]el   [T]oggle Type   [W]ipe & Auto   [B]ack")
        status_bar("A: Add | D: Del | T: Type | W: Auto-Partition")
        
        local _, _, _, code = event.pull("key_down")
        if code == 200 and selected > 1 then selected = selected - 1 
        elseif code == 208 and selected < #drive_mounts then selected = selected + 1 
        elseif code == 30 then -- A
            if drive.uuid ~= "virtual" and free_space < 1024 then status_bar("No space left!"); os.sleep(1) else
                local suggestions = {"/", "/home", "/boot", "/var", "/var/log", "swap", "Custom..."}
                local mp = dropdown_menu(10, row_y + 3, suggestions)
                if mp == "Custom..." then mp = input_box("Custom Mount Point", "/") end
                
                if mp then
                    local ftype = "rootfs"
                    local ipath = "/" 
                    local size = 0
                    
                    if mp == "/" then 
                        ftype = "rootfs"; ipath = "/"
                    elseif mp:find("swap") then 
                        ftype = "swap"; mp = "none"; ipath = "/swapfile"
                    elseif mp:find("log") then 
                        ftype = "ringfs"; ipath = "/log"
                    elseif mp:find("home") then 
                        ftype = "homefs"; ipath = "/home"
                    else
                        ipath = mp
                    end

                    if ftype ~= "rootfs" and drive.uuid ~= "virtual" then
                        size = size_selector(free_space, math.min(free_space, 512*1024))
                    end

                    if size or ftype == "rootfs" then
                        table.insert(State.Mounts, {
                            uuid = drive.uuid, mount = mp, type = ftype, path = ipath,
                            options = "rw", size_limit = size or 0, label = drive.label
                        })
                    end
                end
            end
        elseif code == 32 then -- D
            if #drive_mounts > 0 then
                table.remove(State.Mounts, drive_mounts[selected].idx)
                if selected > 1 then selected = selected - 1 end
            end
        elseif code == 20 then -- T
             if #drive_mounts > 0 then
                local m = State.Mounts[drive_mounts[selected].idx]
                m.type = next_type(m.type)
             end
        elseif code == 17 then -- W
            if drive.uuid ~= "virtual" and confirm_dialog("Wipe & Auto-Partition?") then auto_partition_drive(drive) end
        elseif code == 48 then return end
    end
end

local function run_partition_manager()
    local drives = scan_drives()
    local sel = 1
    while true do
        clear()
        draw_header("Disk Selection")
        center_text(3, ":: PHYSICAL STORAGE DEVICES ::", C_ACCENT)
        local ty = 5
        gpu.setForeground(C_DIM)
        gpu.set(2, ty, "DEVICE LABEL          UUID (SHORT)    CAPACITY   SLICES")
        gpu.set(2, ty+1, string.rep(B.H, W-4))
        ty = ty + 2
        for i, drv in ipairs(drives) do
            if i == sel then gpu.setBackground(C_ACCENT); gpu.setForeground(C_ACCENT_T) 
            else gpu.setForeground(C_TEXT) end
            local parts = 0
            for _, m in ipairs(State.Mounts) do if m.uuid == drv.uuid then parts = parts + 1 end end
            local line = string.format(" %-20s  %-14s  %-10s %-4d", 
                drv.label:sub(1,20), drv.uuid:sub(1,8).."...", format_size(drv.total_size), parts)
            gpu.set(2, ty, line .. string.rep(" ", W - #line - 2))
            gpu.setBackground(C_BG)
            ty = ty + 1
        end
        status_bar("ENTER: Select | B: Back")
        local _, _, _, code = event.pull("key_down")
        if code == 200 and sel > 1 then sel = sel - 1
        elseif code == 208 and sel < #drives then sel = sel + 1
        elseif code == 28 then manage_drive_partitions(drives[sel])
        elseif code == 48 then return end
    end
end

-- === VERSION SELECTOR ===

local function fetch_version_manifest(url)
    local data, err = http_get(url)
    if not data then return nil end
    
    local func = load(data, "verlist", "t", {})
    if not func then return nil end
    
    local status, res = pcall(func)
    if not status or type(res) ~= "table" then return nil end
    
    if not res.versions then res.versions = {} end
    if not res.latest and #res.versions > 0 then res.latest = res.versions[1].id end
    
    if #res.versions == 0 then
        table.insert(res.versions, {id="latest", label="Latest (Unknown)"})
        res.latest = "latest"
    end
    
    return res
end


local function run_version_selector()
    local bw, bh = 60, 16
    local bx, by = math.floor((W-bw)/2), math.floor((H-bh)/2)
    
    -- 1. Download Lists
    gpu.fill(bx, by, bw, bh, " ")
    draw_box(bx, by, bw, bh, "RELEASE CHANNELS", C_ACCENT)
    center_text(by+7, "Fetching release manifest...", C_DIM)
    
    local k_data = fetch_version_manifest(RAW_ROOT .. "/os/KERNEL_VERSIONLIST.lua")
    local e_data = fetch_version_manifest(RAW_ROOT .. "/os/EEPROM_VERSIONLIST.lua")
    
    if not k_data then k_data = { latest="v0.3", versions={{id="v0.3", label="v0.3 (Offline)"}} } end
    if not e_data then e_data = { latest="v0.3", versions={{id="v0.3", label="v0.3 (Offline)"}} } end
    
    local k_lat_idx, e_lat_idx = 1, 1
    for i, v in ipairs(k_data.versions) do if v.id == k_data.latest then k_lat_idx = i break end end
    for i, v in ipairs(e_data.versions) do if v.id == e_data.latest then e_lat_idx = i break end end
    
    local use_latest = true
    local linked = true
    
    local k_idx = k_lat_idx
    local e_idx = e_lat_idx
    
    local active_col = 1 -- 1: KERNEL, 2: LINK, 3: BIOS
    local list_h = bh - 7

    local k_scroll, e_scroll = 0, 0
    
    while true do
        gpu.fill(bx, by, bw, bh, " ")
        draw_box(bx, by, bw, bh, "RELEASE SELECTION", C_ACCENT)
        
        -- Header: Use Latest
        local lat_str = string.format("Use Latest: Kernel [%s] / BIOS [%s]", k_data.latest, e_data.latest)
        if #lat_str > bw-6 then lat_str = "Use Recommended (Latest)" end
        
        gpu.setForeground(use_latest and C_ACCENT or C_DIM)
        gpu.set(bx+2, by+2, "[ "..(use_latest and "x" or " ").." ] " .. lat_str)
        
        -- Columns Headers
        gpu.setForeground(C_TEXT)
        gpu.set(bx+2, by+4, "KERNEL VERSION")
        gpu.set(bx+23, by+4, "LINK")
        gpu.set(bx+32, by+4, "BIOS VERSION")
        gpu.set(bx+2, by+5, string.rep(B.H, bw-4))
        
        -- Drawing Logic
        local function draw_list(x, items, sel_idx, scroll_off, is_active_col)
            for i=1, list_h do
                local y = by + 5 + i
                local idx = i + scroll_off
                
                if items[idx] then
                    local is_sel = (idx == sel_idx)
                    local label = items[idx].label or items[idx].id
                    label = label:sub(1, 18)
                    
                    if use_latest then
                        local is_lat_item = (items[idx].id == (x==bx+2 and k_data.latest or e_data.latest))
                        gpu.setBackground(is_lat_item and C_DIM or C_BG)
                        gpu.setForeground(C_DIM)
                    else
                        if is_sel then
                            if is_active_col then gpu.setBackground(C_ACCENT); gpu.setForeground(C_ACCENT_T)
                            else gpu.setBackground(C_DIM); gpu.setForeground(C_TEXT) end
                        else
                            gpu.setBackground(C_BG); gpu.setForeground(C_TEXT)
                        end
                    end
                    
                    gpu.set(x, y, label .. string.rep(" ", 19 - #label))
                    gpu.setBackground(C_BG)
                end
            end
        end
        
        -- Adjust Scroll to keep selection in view
        if k_idx > k_scroll + list_h then k_scroll = k_idx - list_h elseif k_idx <= k_scroll then k_scroll = k_idx - 1 end
        if e_idx > e_scroll + list_h then e_scroll = e_idx - list_h elseif e_idx <= e_scroll then e_scroll = e_idx - 1 end

        -- Draw Lists
        draw_list(bx+2, k_data.versions, k_idx, k_scroll, active_col == 1)
        draw_list(bx+32, e_data.versions, e_idx, e_scroll, active_col == 3)
        
        -- Draw Link Button
        local btn_y = by + 5 + math.ceil(list_h/2)
        local btn_txt = linked and "< - >" or "< / >"
        if active_col == 2 and not use_latest then gpu.setForeground(C_ACCENT) else gpu.setForeground(C_DIM) end
        gpu.set(bx+24, btn_y, "[ "..btn_txt.." ]")
        
        status_bar("ARROWS: Move | SPACE: Toggle | ENTER: Confirm")
        
        local _, _, _, code = event.pull("key_down")
        
        if code == 28 then -- Enter
            if use_latest then 
                return k_data.latest, e_data.latest 
            else 
                return k_data.versions[k_idx].id, e_data.versions[e_idx].id 
            end
            
        elseif code == 57 then -- Space
            if use_latest then 
                use_latest = false
            elseif active_col == 2 then 
                linked = not linked 
            elseif active_col == 1 or active_col == 3 then 
                use_latest = true
                k_idx = k_lat_idx
                e_idx = e_lat_idx
            end
            
        elseif not use_latest then
            if code == 203 then -- Left
                 if active_col > 1 then active_col = active_col - 1 end
            elseif code == 205 then -- Right
                 if active_col < 3 then active_col = active_col + 1 end
            elseif code == 200 then -- Up
                if active_col == 1 then
                    if k_idx > 1 then k_idx = k_idx - 1; if linked then e_idx = math.min(k_idx, #e_data.versions) end end
                elseif active_col == 3 then
                    if e_idx > 1 then e_idx = e_idx - 1; if linked then k_idx = math.min(e_idx, #k_data.versions) end end
                end
            elseif code == 208 then -- Down
                if active_col == 1 then
                    if k_idx < #k_data.versions then k_idx = k_idx + 1; if linked then e_idx = math.min(k_idx, #e_data.versions) end end
                elseif active_col == 3 then
                    if e_idx < #e_data.versions then e_idx = e_idx + 1; if linked then k_idx = math.min(e_idx, #k_data.versions) end end
                end
            end
        end
    end
end

-- === PACKAGE SELECTOR ===
local function collect_selected_packages(nodes, result_table)
    if not nodes then return end
    for _, item in ipairs(nodes) do
        if item.type == "file" and item.selected then table.insert(result_table, item)
        elseif item.type == "tree" then collect_selected_packages(item.items, result_table) end
    end
end

local function run_package_selector()
    if not State.RepoCache or #State.RepoCache == 0 then
        local bx, by = math.floor(W/2)-20, math.floor(H/2)-2
        gpu.fill(bx, by, 40, 5, " "); draw_box(bx, by, 40, 5, "SYNCING REPOS", C_ACCENT)
        gpu.set(bx+2, by+2, "Downloading package manifest...")
        
        local data, err = http_get(RAW_ROOT .. "/PKGLIST.lua")
        if not data then
            center_text(by+2, "DL Failed: " .. tostring(err), C_ERR); State.RepoCache = {}; os.sleep(2)
        else
            data = data:gsub("^%s+", ""):gsub("^\239\187\191", "")
            local func = load(data, "pkglist", "t", {})
            if func then
                local status, result = pcall(func)
                if status and type(result) == "table" then State.RepoCache = result
                else gpu.setForeground(C_ERR); center_text(by+2, "Invalid PKGLIST"); State.RepoCache = {}; os.sleep(3) end
            else center_text(by+2, "Syntax Error in PKGLIST", C_ERR); State.RepoCache = {}; os.sleep(2) end
        end
    end
    
    local cat_idx, file_idx, active_pane = 1, 1, 1 
    local folder_stack = {}
    local function get_current_list()
        if #folder_stack > 0 then return folder_stack[#folder_stack].list end
        if State.RepoCache[cat_idx] then return State.RepoCache[cat_idx].items end return {}
    end

    while true do
        clear(); draw_header("Axispkg // Select Packages")
        local pane_w, pane_h = math.floor((W - 4) / 2), H - 6
        
        draw_box(2, 3, pane_w, pane_h + 2, "REPOSITORIES", active_pane==1 and C_ACCENT or C_DIM)
        if #State.RepoCache == 0 then gpu.set(3, 5, "No Repo Data.") else
            for i, cat in ipairs(State.RepoCache) do
                if i == cat_idx then gpu.setBackground(active_pane==1 and C_ACCENT or C_PANEL); gpu.setForeground(C_ACCENT_T) else gpu.setForeground(C_TEXT) end
                gpu.set(3, 4+i, " " .. cat.name .. string.rep(" ", pane_w - #cat.name - 3)); gpu.setBackground(C_BG)
            end
        end
        
        local current_items = get_current_list() or {}
        local display_list = {}
        if #folder_stack > 0 then table.insert(display_list, { is_back = true, name = "[ .. ] Back" }) end
        for _, itm in ipairs(current_items) do table.insert(display_list, itm) end
        
        local title_right = (#folder_stack > 0) and folder_stack[#folder_stack].name or "PACKAGES"
        draw_box(2 + pane_w, 3, pane_w, pane_h + 2, title_right, active_pane==2 and C_ACCENT or C_DIM)
        
        local limit = pane_h
        local offset = file_idx > limit and file_idx - limit or 0
        
        for i=1, limit do
            local idx = i + offset
            if idx > #display_list then break end
            local item = display_list[idx]
            if idx == file_idx then gpu.setBackground(active_pane==2 and C_ACCENT or C_PANEL); gpu.setForeground(C_ACCENT_T) else gpu.setForeground(C_TEXT) end
            local txt = item.is_back and (" " .. item.name) or (item.type == "tree" and (" > " .. item.name .. "/") or string.format(" %s %s", item.selected and "[*]" or "[ ]", item.name))
            gpu.set(3 + pane_w, 4+i, txt .. string.rep(" ", pane_w - unicode.len(txt) - 2)); gpu.setBackground(C_BG)
        end
        status_bar("TAB: Switch | SPACE: Select | ENTER: Open Folder | S: Save")
        
        local _, _, _, code = event.pull("key_down")
        if code == 15 then active_pane = (active_pane == 1) and 2 or 1; if active_pane == 1 then folder_stack = {} end
        elseif code == 200 then
            if active_pane == 1 then if cat_idx > 1 then cat_idx=cat_idx-1; file_idx=1; folder_stack={} end
            else if file_idx > 1 then file_idx=file_idx-1 end end
        elseif code == 208 then
            if active_pane == 1 then if cat_idx < #State.RepoCache then cat_idx=cat_idx+1; file_idx=1; folder_stack={} end
            else if file_idx < #display_list then file_idx=file_idx+1 end end
        elseif code == 57 and active_pane == 2 then
            local item = display_list[file_idx]
            if item and not item.is_back and item.type == "file" then item.selected = not item.selected end
        elseif code == 28 and active_pane == 2 then
            local item = display_list[file_idx]
            if item then
                if item.is_back then table.remove(folder_stack); file_idx = 1
                elseif item.type == "tree" then table.insert(folder_stack, { list = item.items, name = item.name }); file_idx = 1 end
            end
        elseif code == 31 then
            State.Packages = {}; for _, cat in ipairs(State.RepoCache) do collect_selected_packages(cat.items, State.Packages) end; return
        elseif code == 48 then return end
    end
end

local install_log_buffer = {}
local LOG_HEIGHT = H - 12

local function draw_install_interface(target_label, target_uuid, k_ver, b_ver)
    clear()
    draw_header("System Deployment")
    draw_box(2, 3, W - 28, LOG_HEIGHT + 2, " ACTION LOG ", C_ACCENT)
    draw_box(W - 24, 3, 24, LOG_HEIGHT + 2, " SYSTEM STATS ", C_DIM)
    
    gpu.setForeground(C_ACCENT); gpu.set(W - 22, 5, "TARGET DRIVE:")
    gpu.setForeground(C_TEXT);   gpu.set(W - 22, 6, target_label:sub(1,18))
    gpu.setForeground(C_DIM);    gpu.set(W - 22, 7, target_uuid:sub(1,8).."...")
    
    gpu.setForeground(C_ACCENT); gpu.set(W - 22, 9, "VERSION TARGET:")
    gpu.setForeground(C_TEXT);   gpu.set(W - 22, 10, k_ver or "Latest")
    gpu.setForeground(C_DIM);    gpu.set(W - 22, 11, "BIOS: " .. (b_ver or "Latest"))
    
    gpu.setForeground(C_ACCENT); gpu.set(W - 22, 13, "MEMORY:")
end

local function update_stats()
    local free = computer.freeMemory()
    local total = computer.totalMemory()
    local used_pct = math.floor(((total-free)/total)*100)
    gpu.setBackground(C_BG); gpu.setForeground(C_TEXT); gpu.set(W - 22, 14, string.format("%d%% Used", used_pct))
    gpu.setForeground(C_DIM); gpu.set(W - 22, 15, format_size(free) .. " free")
    gpu.setForeground(C_ACCENT); gpu.set(W - 22, 17, "UPTIME:")
    gpu.setForeground(C_TEXT); gpu.set(W - 22, 18, string.format("%.1fs", computer.uptime()))
end

local function install_log(msg, status_col)
    local time = os.date("%T")
    local line = string.format("[%s] %s", time, msg)
    table.insert(install_log_buffer, {text=line, col=status_col or C_TEXT})
    if #install_log_buffer > LOG_HEIGHT then table.remove(install_log_buffer, 1) end
    for i, log in ipairs(install_log_buffer) do
        gpu.set(4, 3 + i, string.rep(" ", W - 32))
        gpu.setForeground(log.col); gpu.set(4, 3 + i, log.text)
    end
end

local function update_progress_detail(curr, total, filename, last_speed, last_size)
    local pct = curr / total
    local by = H - 5
    gpu.setBackground(C_BG); gpu.fill(2, by, W-2, 5, " ")
    gpu.setForeground(C_ACCENT); gpu.set(2, by, "CURRENT: "); gpu.setForeground(C_TEXT); gpu.set(11, by, filename)
    if last_size then
        local info = string.format("SZ: %s | SPD: %s/s", format_size(last_size), format_size(last_speed))
        gpu.set(W - #info - 2, by, info)
    end
    gpu.setForeground(C_DIM); gpu.set(2, by+2, "["); gpu.set(W-1, by+2, "]")
    local inner_w = W - 4; local fill_w = math.floor(inner_w * pct)
    gpu.setBackground(C_PANEL); gpu.fill(3, by+2, inner_w, 1, " "); gpu.setBackground(C_ACCENT); gpu.fill(3, by+2, fill_w, 1, " ")
    gpu.setBackground(C_BG); gpu.setForeground(C_TEXT); local pct_str = math.floor(pct * 100) .. "%"
    gpu.set(math.floor(W/2 - #pct_str/2), by+3, pct_str)
end

local function install_os(kernel_ver, bios_ver)
    if not data_card then if not confirm_dialog("NO DATA CARD! DL MAY FAIL. CONT?") then return end end

    local root_uuid = nil
    for _, m in ipairs(State.Mounts) do if m.mount == "/" then root_uuid = m.uuid end end

    if not root_uuid then
        local drives = scan_drives()
        if #drives > 0 and drives[1].uuid ~= "virtual" then
            auto_partition_drive(drives[1])
            for _, m in ipairs(State.Mounts) do if m.mount == "/" then root_uuid = m.uuid end end
        end
    end

    if not root_uuid then status_bar("Error: No Root Partition!"); os.sleep(2); return end
    local proxy = component.proxy(root_uuid)
    if not proxy then status_bar("Error: Drive disconnected"); os.sleep(2); return end
    
    draw_install_interface(proxy.getLabel() or "HDD", root_uuid, kernel_ver, bios_ver)
    install_log("Installation initialized.", C_ACCENT)
    install_log("Selected Version: " .. kernel_ver, C_DIM)
    
    -- 1. Wipe Root
    install_log("Formatting filesystem...", C_WARN)
    update_progress_detail(0, 100, "Formatting...", 0, 0)
    local list = proxy.list("/")
    for _, file in ipairs(list) do proxy.remove(file) end
    install_log("Filesystem formatted. Label set to AxisOS.", C_SUCCESS)
    update_stats()

    -- 2. Download Core (USING VERSION)
    local total_files = #CORE_MANIFEST + #State.Packages + 2
    local current_step = 0
    
    for i, rel_path in ipairs(CORE_MANIFEST) do
        current_step = current_step + 1
        local start_t = computer.uptime()
        
        update_progress_detail(current_step, total_files, rel_path, 0, 0)
        install_log("Downloading " .. rel_path .. "...", C_TEXT)
        update_stats()
        
        -- DYNAMIC URL CONSTRUCTION
        -- Format: http://repo.../os/v0.3/kernel/bin/init.lua
        local url = string.format("%s/os/%s/kernel/%s", RAW_ROOT, kernel_ver, rel_path)
        
        local data, err = http_get(url)
        local end_t = computer.uptime()
        local duration = end_t - start_t
        local size = data and #data or 0
        local speed = size / (duration > 0 and duration or 0.1)
        
        if data then
            local parent = get_parent_dir(rel_path)
            if parent ~= "" then proxy.makeDirectory("/" .. parent) end
            local h = proxy.open("/" .. rel_path, "w")
            proxy.write(h, data)
            proxy.close(h)
            update_progress_detail(current_step, total_files, rel_path, speed, size)
            install_log("  -> OK (" .. format_size(size) .. ")", C_SUCCESS)
        else
            install_log("  -> FAILED: " .. tostring(err), C_ERR)
            os.sleep(0.5)
        end
    end
    
    -- 3. Install Packages (FROM PACKAGES ROOT, NOT VERSIONED YET)
    if #State.Packages > 0 then
        install_log("Processing extra packages...", C_ACCENT)
        for i, p in ipairs(State.Packages) do
            current_step = current_step + 1
            update_progress_detail(current_step, total_files, p.name, 0, 0)
            install_log("Fetching package: " .. p.name)
            update_stats()
            
            local pre = "/usr/misc"
            if p.path:find("drivers") then pre = "/drivers"
            elseif p.path:find("executable") then pre = "/usr/commands"
            elseif p.path:find("modules") then pre = "/lib"
            end
            
            proxy.makeDirectory(pre)
            local url = RAW_ROOT .. "/" .. p.path
            local data, err = http_get(url)
            
            if data then
                local h = proxy.open(pre .. "/" .. p.name, "w")
                proxy.write(h, data)
                proxy.close(h)
                install_log("  -> Installed to " .. pre, C_SUCCESS)
            else
                install_log("  -> PKG ERROR: " .. tostring(err), C_ERR)
            end
        end
    end
    
    -- 4. Gen Configs
    install_log("Generating system configuration...", C_ACCENT)
    update_progress_detail(total_files-1, total_files, "/etc/fstab.lua", 0, 0)
    
    table.sort(State.Mounts, function(a, b) return (a.type == "rootfs") and not (b.type == "rootfs") end)
    local fstab = "-- Axis OS File System Table\nreturn {\n"
    for _, m in ipairs(State.Mounts) do
        if m.uuid ~= "virtual" then
            local opts = "rw"
            if m.type ~= "rootfs" and m.size_limit and m.size_limit > 0 then opts = opts .. ",size=" .. math.floor(m.size_limit) end
            local ipath = m.path or (m.type == "rootfs" and "/" or (m.type == "swap" and "/swapfile" or m.mount))
            fstab = fstab .. string.format('  { uuid = "%s", path = "%s", mount = "%s", type = "%s", options = "%s", },\n', m.uuid, ipath, m.mount, m.type, opts)
        end
    end
    fstab = fstab .. '  { uuid = "virtual", path = "/dev/ringlog", mount = "/var/log/syslog", type = "ringfs", options = "rw,size=8192", },\n}'
    
    proxy.makeDirectory("/etc")
    local function wcf(p, c) local h=proxy.open(p,"w"); proxy.write(h,c); proxy.close(h) end
    wcf("/etc/fstab.lua", fstab)
    
    local pwd = string.format('return {\n  root={uid=0, home="/root", shell="/bin/sh.lua", hash="%s", ring=3},\n', string.reverse(State.RootPass) .. "AURA_SALT")
    proxy.makeDirectory("/home")
    for _, u in ipairs(State.Users) do
        pwd = pwd .. string.format('  ["%s"]={uid=%d, home="/home/%s", shell="/bin/sh.lua", hash="%s", ring=%d},\n',
             u.name, u.sudo and 0 or 1000, u.name, string.reverse(u.pass) .. "AURA_SALT", u.sudo and 0 or 3) -- etc/passwd
        proxy.makeDirectory("/home/" .. u.name) -- create home dir for every user
    end
    pwd = pwd .. "}"
    wcf("/etc/passwd.lua", pwd)
    wcf("/etc/hostname", State.Hostname)
    
    -- 5. BIOS (USING VERSION)
    if component.isAvailable("eeprom") then
        install_log("Initializing firmware update...", C_WARN)
        update_progress_detail(total_files, total_files, "EEPROM", 0, 0)
        
        -- DYNAMIC URL FOR BIOS
        local url = string.format("%s/os/%s/eeprom/boot.lua", RAW_ROOT, bios_ver)
        local biosCode, err = http_get(url)
        
        if biosCode then
            if not (biosCode:match("local") or biosCode:match("return")) then
                install_log("BIOS ERR: Content invalid!", C_ERR); os.sleep(3)
            else
                install_log("Writing to EEPROM ("..bios_ver..")...", C_ACCENT)
                local flash_res, flash_err = pcall(component.eeprom.set, biosCode)
                if flash_res then
                    component.eeprom.setLabel("AxisBIOS " .. bios_ver)
                    component.eeprom.setData(root_uuid)
                    if component.eeprom.get() == biosCode then
                        install_log("BIOS VERIFIED [OK]", C_SUCCESS)
                        pcall(computer.setBootAddress, root_uuid)
                    else
                        install_log("BIOS VERIFY FAILED!", C_ERR); os.sleep(1)
                        component.eeprom.set(biosCode)
                    end
                else
                    install_log("FLASH ERR: " .. tostring(flash_err), C_ERR); os.sleep(3)
                end
            end
        else
            install_log("BIOS DL FAIL: " .. tostring(err), C_ERR); os.sleep(2)
        end
    end
    
    update_progress_detail(100, 100, "DONE", 0, 0)
    install_log("Installation Complete.", C_SUCCESS)
    install_log("Rebooting in 3 seconds...", C_ACCENT)
    os.sleep(3)
    computer.shutdown(true)
end

-- === MAIN LOOP ===

local function main_menu()
    local menu_state = 1
    local exit_and_clear = function() gpu.setBackground(C_ORIGINAL_BG) gpu.setForeground(C_ORIGINAL_FG) gpu.fill(1, 1, W, H, " ") os.exit() end
    while true do
        clear()
        draw_header()
        draw_dashboard()
        
        local mx, my = 38, 3
        local mw = W - mx - 2
        local mh = H - 5
        
        draw_box(mx, my, mw, mh, " CONFIGURATION ", C_ACCENT)
        
        local root_dev = "Not Selected"
        for _, m in ipairs(State.Mounts) do if m.mount == "/" then root_dev = m.uuid:sub(1,8).."..." end end
        
        local items = {
            { txt="Disk Configuration", val="[ "..root_dev.." ]", fn=run_partition_manager },
            { txt="Packages",           val="[ "..#State.Packages.." Selected ]", fn=run_package_selector },
            { txt="Hostname",           val="[ "..State.Hostname.." ]", fn=function() State.Hostname = input_box("Hostname", State.Hostname) or State.Hostname end },
            { txt="Root Password",      val="[ "..(State.RootPass == "toor" and "Default" or "*****").." ]", fn=function() State.RootPass = input_box("Root Password", State.RootPass, true) or State.RootPass end },
            { txt="User Accounts",      val="[ "..#State.Users.." Created ]", fn=function() 
                 local u = input_box("Username", "")
                 if u then table.insert(State.Users, {name=u, pass=input_box("Password", "", true), sudo=false}) end
            end },
            { txt="------------------", val="", fn=nil },
            { txt="Install Axis OS",    val=">>>", fn=function() 
                local k, b = run_version_selector()
                if k and b then install_os(k, b) end
            end },
            { txt="Abort",              val="", fn=function() if confirm_dialog("Quit?") then exit_and_clear() end end }
        }
        
        local iy = my + 2
        for i, item in ipairs(items) do
            if item.fn then
                if i == menu_state then gpu.setForeground(C_ACCENT); gpu.set(mx+2, iy, "> " .. item.txt)
                else gpu.setForeground(C_TEXT); gpu.set(mx+2, iy, "  " .. item.txt) end
                if item.val ~= "" then
                    gpu.setForeground(i == menu_state and C_ACCENT or C_DIM); gpu.set(mx + mw - #item.val - 2, iy, item.val)
                end
            else
                gpu.setForeground(C_DIM); gpu.set(mx+2, iy, string.rep(B.H, mw-4))
            end
            iy = iy + 1
        end

        local _, _, _, code = event.pull("key_down")
        if code == 200 then repeat menu_state = menu_state - 1; if menu_state < 1 then menu_state = #items end until items[menu_state].fn
        elseif code == 208 then repeat menu_state = menu_state + 1; if menu_state > #items then menu_state = 1 end until items[menu_state].fn
        elseif code == 28 then if items[menu_state].fn then items[menu_state].fn() end
        elseif code == 16 then if confirm_dialog("Quit?") then exit_and_clear() end end
    end
end

gpu.setResolution(W, H)
main_menu()