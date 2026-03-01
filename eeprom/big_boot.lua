-- Nyanity Modular BIOS v6.00PG (AxisOS Port)
-- v4.3: Dynamic Memory Test | Ocelot Fix | Max Res

local component = component
local computer = computer
local unicode = unicode
local gpu, screen, internet

-- =============================================================================
-- HARDWARE & INIT
-- =============================================================================
for addr, type in component.list() do
  if type == "gpu" and not gpu then gpu = component.proxy(addr) end
  if type == "screen" and not screen then screen = addr end
  if type == "internet" and not internet then internet = component.proxy(addr) end
end
if not gpu or not screen then computer.beep(1000,0.2); error("NO VIDEO") end
gpu.bind(screen)

-- USE MAX RESOLUTION
local mw, mh = gpu.maxResolution()
gpu.setResolution(mw, mh)
local w, h = gpu.getResolution()

-- =============================================================================
-- STATE & CONFIG
-- =============================================================================
local tBootArgs = {
  loglevel = "Info",
  safemode = "Disabled",
  timeout = "3",
  quick = "Disabled",
  init = "/bin/init.lua"
}

local sDate, sTime = "01/01/1970", "00:00:00"
if internet then
  pcall(function()
    internet.request("http://worldtimeapi.org/api/timezone/Etc/UTC.txt")
  end)
end

-- =============================================================================
-- GRAPHICS
-- =============================================================================
local C_BLUE   = 0x0000AA
local C_RED    = 0xAA0000
local C_YELLOW = 0xFFFF00
local C_WHITE  = 0xFFFFFF
local C_GREY   = 0xC0C0C0
local C_BLACK  = 0x000000

local function color(bg, fg) gpu.setBackground(bg); gpu.setForeground(fg) end
local function clear(bg) color(bg, C_GREY); gpu.fill(1, 1, w, h, " ") end

local function center(y, text, fg) 
  local x = math.floor((w - unicode.len(text)) / 2)
  if fg then gpu.setForeground(fg) end
  gpu.set(x, y, text) 
end

local function draw_border_box(x, y, bw, bh)
  local sH = string.rep("═", bw - 2)
  gpu.set(x, y, "╔" .. sH .. "╗")
  gpu.set(x, y + bh - 1, "╚" .. sH .. "╝")
  for i = 1, bh - 2 do
    gpu.set(x, y + i, "║")
    gpu.set(x + bw - 1, y + i, "║")
  end
end

local function wait_key()
  while true do
    local sig, _, char, code = computer.pullSignal()
    if sig == "key_down" then return char, code end
  end
end

computer.pullSignal(0.1)

-- =============================================================================
-- MENUS DATA
-- =============================================================================
local tMenus = {
  { label = "Standard CMOS Features", type = "submenu", items = {
      { id="date", label="Date", type="info", val=function() return sDate end },
      { id="time", label="Time", type="info", val=function() return sTime end },
      { id="mem",  label="Base Memory", type="info", val="640K" },
      { id="ext",  label="Extended Memory", type="info", val=tostring((computer.totalMemory()//1024)-640).."K" },
  }},
  { label = "Advanced BIOS Features", type = "submenu", items = {
      { id="quick", label="Quick Power On Self Test", options={"Enabled","Disabled"} },
      { id="timeout", label="Boot Delay (sec)", type="input" },
      { id="init", label="Init Image Path", type="input" },
  }},
  { label = "Advanced Chipset Features", type = "submenu", items = {
      { id="loglevel", label="Kernel Log Level", options={"Debug","Info","Warn","Error"} },
      { id="safemode", label="Safe Mode", options={"Enabled","Disabled"} },
  }},
  { label = "Integrated Peripherals", type = "dummy" },
  { label = "Power Management Setup", type = "dummy" },
  { label = "PnP/PCI Configurations", type = "dummy" },
  { label = "PC Health Status",       type = "dummy" },
  { label = "Frequency/Voltage Control", type = "dummy", col=2 },
  { label = "Load Fail-Safe Defaults",   type = "action", col=2, func=function() end },
  { label = "Load Optimized Defaults",   type = "action", col=2, func=function() end },
  { label = "Set Supervisor Password",   type = "dummy", col=2 },
  { label = "Set User Password",         type = "dummy", col=2 },
  { label = "Save & Exit Setup",         type = "exit_save", col=2 },
  { label = "Exit Without Saving",       type = "exit_nosave", col=2 },
}

-- =============================================================================
-- LOGIC
-- =============================================================================

local function run_submenu(menu_def)
  local sel = 1
  local items = menu_def.items
  local box_w = math.floor(w * 0.8)
  local box_h = #items + 4
  local box_x = math.floor((w - box_w) / 2)
  local box_y = math.floor((h - box_h) / 2)
  
  while true do
    color(C_BLUE, C_GREY)
    gpu.fill(box_x, box_y, box_w, box_h, " ")
    draw_border_box(box_x, box_y, box_w, box_h)
    color(C_GREY, C_BLACK)
    gpu.set(box_x + 2, box_y, " " .. menu_def.label .. " ")
    
    for i, item in ipairs(items) do
      local y = box_y + 1 + i
      local val = tBootArgs[item.id]
      if item.val then 
         if type(item.val)=="function" then val = item.val() else val = item.val end 
      end
      if not val then val = "" end
      local label = item.label
      local pad = (box_w - 4) - unicode.len(label) - unicode.len(val)
      local line = " " .. label .. string.rep(" ", pad) .. val .. " "
      if i == sel then color(C_RED, C_WHITE) else color(C_BLUE, C_GREY) end
      gpu.set(box_x + 2, y, line)
    end
    
    local char, code = wait_key()
    if code == 1 or code == 14 then return 
    elseif code == 200 and sel > 1 then sel = sel - 1
    elseif code == 208 and sel < #items then sel = sel + 1
    elseif code == 28 then 
       local it = items[sel]
       if it.options then
          local idx = 1
          for j,v in ipairs(it.options) do if v == tBootArgs[it.id] then idx = j end end
          idx = idx + 1; if idx > #it.options then idx = 1 end
          tBootArgs[it.id] = it.options[idx]
       elseif it.type == "input" then
          color(C_RED, C_WHITE)
          local iw, ih = 30, 3
          local ix, iy = math.floor((w-iw)/2), math.floor((h-ih)/2)
          gpu.fill(ix, iy, iw, ih, " "); draw_border_box(ix, iy, iw, ih)
          local inp = ""
          while true do
             gpu.set(ix+2, iy+1, inp.."_  ")
             local c, k = wait_key()
             if k == 28 then tBootArgs[it.id] = inp; break
             elseif k == 14 then inp = unicode.sub(inp, 1, -2)
             elseif c>32 and c<127 and unicode.len(inp)<(iw-4) then inp=inp..unicode.char(c) end
          end
       end
    end
  end
end

local function run_setup()
  local sel = 1
  local col1_x = 2
  local col_w = math.floor(w / 2) - 3
  local col2_x = col1_x + col_w + 2
  local main_h = h - 6
  
  
  while true do
    clear(C_BLUE)
    color(C_GREY, C_BLACK); gpu.fill(1, 1, w, 1, " ")
    center(1, "CMOS Setup Utility - Copyright (C) 2026 Nyanity Memetic Software")
    color(C_BLUE, C_WHITE)
    draw_border_box(col1_x, 3, col_w, main_h)
    draw_border_box(col2_x, 3, col_w, main_h)
    draw_border_box(2, h-3, w-4, 4)
    color(C_BLUE, C_YELLOW)
    local sArrows = unicode.char(0x2191)..unicode.char(0x2193)..unicode.char(0x2192)..unicode.char(0x2190)
    gpu.set(4, h-2, "Esc : Quit"); gpu.set(col2_x, h-2, sArrows.." : Select Item")
    gpu.set(4, h-1, "F10 : Save & Exit Setup")
    
    local left_idx, right_idx = 0, 0
    for i, m in ipairs(tMenus) do
      local x, y, box_w
      if (m.col or 1) == 1 then
         x = col1_x + 2; y = 4 + left_idx; left_idx = left_idx + 1; box_w = col_w - 4
      else
         x = col2_x + 2; y = 4 + right_idx; right_idx = right_idx + 1; box_w = col_w - 4
      end
      local label = m.label
      if m.type == "submenu" then label = "\16 " .. label end
      if i == sel then
         color(C_RED, C_WHITE)
         label = label .. string.rep(" ", box_w - unicode.len(label))
      else
         if m.type == "dummy" then color(C_BLUE, C_GREY) else color(C_BLUE, C_YELLOW) end
      end
      gpu.set(x, y, label)
    end
    
    color(C_BLUE, C_WHITE)
    center(h/2 + 5, "Time, Date, Hard Disk Type...", C_GREY)
    
    local char, code = wait_key()
    if code == 200 then sel = sel - 1; if sel < 1 then sel = #tMenus end
    elseif code == 208 then sel = sel + 1; if sel > #tMenus then sel = 1 end
    elseif code == 205 then if sel <= 7 then sel = sel + 7 end; if sel > #tMenus then sel = #tMenus end
    elseif code == 203 then if sel > 7 then sel = sel - 7 end
    elseif code == 68 then return
    elseif code == 1 then return
    elseif code == 28 then 
       local m = tMenus[sel]
       if m.type == "submenu" then run_submenu(m)
       elseif m.type == "exit_save" then return
       elseif m.type == "exit_nosave" then computer.shutdown(true) end
    end
  end
end

-- =============================================================================
-- POST & BOOT
-- =============================================================================
local logo = {
"   ░███                                              ░██████     ░██████   ",
"  ░██░██                                            ░██   ░██   ░██   ░██  ",
" ░██  ░██  ░██    ░██    ░██  ░███████   ░███████  ░██     ░██ ░██         ",
"░█████████ ░██    ░██    ░██ ░██    ░██ ░██    ░██ ░██     ░██  ░████████  ",
"░██    ░██  ░██  ░████  ░██  ░██    ░██ ░██    ░██ ░██     ░██         ░██ ",
"░██    ░██   ░██░██ ░██░██   ░██    ░██ ░██    ░██  ░██   ░██   ░██   ░██  ",
"░██    ░██    ░███   ░███     ░███████   ░███████    ░██████     ░██████   "
}

-- SPLASH SCREEN WITH DYNAMIC MEMORY TEST
local function splash(bSkipMemTest)
  clear(C_BLACK)
  color(C_BLACK, C_WHITE)
  
  gpu.set(1, 1, "BIOS v0.3, An Energy Star Ally")
  gpu.set(1, 2, "Copyright (C) 2026, Axis")
  gpu.set(1, 4, "AxisOS Kernel Processor - Tier 3 (APU)")
  
  -- MEMORY TEST LOGIC
  local nTotalMem = computer.totalMemory()
  local nTotalKB = math.floor(nTotalMem / 1024)
  
  if bSkipMemTest then
     gpu.set(1, 5, "Memory Test: " .. nTotalKB .. "K OK")
  else
     -- Dynamic counting
     local nCurrent = 0
     local nStep = math.ceil(nTotalMem / 5) -- ~40 frames total
     
     while nCurrent < nTotalMem do
        nCurrent = nCurrent + nStep
        if nCurrent > nTotalMem then nCurrent = nTotalMem end
        
        local nDisplayKB = math.floor(nCurrent / 1024)
        gpu.set(1, 5, "Memory Test: " .. nDisplayKB .. "K")
        
        -- Check for DEL key DURING memtest to enter setup faster
        local sig, _, _, code = computer.pullSignal(0.01) -- Fast tick
        if sig == "key_down" and code == 211 then -- DEL
           return "SETUP"
        end
     end
     gpu.set(1, 5, "Memory Test: " .. nTotalKB .. "K OK")
     computer.beep(1100, 0.1)
  end
  
  color(C_BLACK, C_GREY)
  local ly = math.floor(h/3)
  for i,l in ipairs(logo) do center(ly+i, l) end
  
  color(C_BLACK, C_WHITE)
  
  gpu.set(1, h-2, "Press DEL to enter SETUP")
  gpu.set(1, h-1, "01/01/2026-AxisOS-0.21-2A69K")
  return nil
end

-- MAIN BOOT LOOP
local action = splash(false) -- Run memtest on first boot
if action == "SETUP" then
   -- computer.pullSignal(0.1)
   computer.beep(1000, 0.01)
   run_setup()
   splash(true) -- Skip memtest after setup
end

local delay = tonumber(tBootArgs.timeout) or 3
if tBootArgs.quick == "Enabled" then delay = 0.1 end
local deadline = computer.uptime() + delay
local bar_w = math.floor(w / 2)

while computer.uptime() < deadline do
  local left = deadline - computer.uptime()
  local fill = math.floor((1 - (left/delay)) * bar_w)
  color(C_BLACK, C_WHITE)
  gpu.set(math.floor((w-bar_w)/2), h-4, "["..string.rep("=",fill)..string.rep("-",bar_w-fill).."]")
  
  local sig,_,_,code = computer.pullSignal(0.1)
  if sig == "key_down" and code == 211 then -- DEL
    run_setup()
    splash(true) -- Skip memtest on redraw
    deadline = computer.uptime() + 0.1
  end
end

-- BOOTLOADER
local fs_addr
for addr in component.list("filesystem") do
  if component.proxy(addr).exists("/kernel.lua") then fs_addr = addr; break end
end

if not fs_addr then 
  clear(C_BLACK); gpu.set(1,1,"DISK BOOT FAILURE, INSERT SYSTEM DISK AND PRESS ENTER")
  while true do computer.pullSignal() end
end

clear(C_BLACK)
gpu.set(1,1,"Booting from local disk...")

local proxy = component.proxy(fs_addr)
local hF = proxy.open("/kernel.lua", "r")
computer.pullSignal(0.1)
computer.beep(900, 0.3)
local code = ""
while true do local d=proxy.read(hF, math.huge); if not d then break; end; code=code..d end
proxy.close(hF)

if code:sub(1,3) == "\239\187\191" then code = code:sub(4) end

local kEnv = {
  raw_component = component,
  raw_computer = computer,
  boot_fs_address = fs_addr,
  boot_args = tBootArgs 
}
setmetatable(kEnv, {__index=_G})

local f, err = load(code, "=kernel", "t", kEnv)
if not f then error(err) end
f()