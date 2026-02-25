--
-- /system/desktop.lua
-- AxisOS Desktop — Start Menu, Taskbar, Window Management
--

local fs   = require("filesystem")
local oSys = require("syscall")

local sUser = env.USER or "user"
local nUid  = env.UID or 1000
local sHome = env.HOME or "/"
local sHost = env.HOSTNAME or "localhost"
local tCfg  = env.DM_CONFIG or {}

local tGpu = syscall("gdi_get_gpu_info", 1)
if not tGpu then return end
local W, H = tGpu.nW, tGpu.nH

-- Colors 

local C_BG      = tCfg.wallpaper_color or 0x0C0C1E
local C_FG      = 0xCCCCDD
local C_ACCENT  = tCfg.accent_color or 0x55FFFF
local C_DIM     = 0x444466
local C_TB_BG   = 0x0D1B32
local C_TB_FG   = 0xCCCCDD
local C_TB_SEL  = 0xFFFF00
local C_CLOCK   = 0x55FF55
local C_ICON_BG = 0x162040
local C_ICON_FG = 0x55DDFF

syscall("gdi_set_desktop_background", C_FG, C_BG)

-- Surfaces 

local TB_H = 1
local nDesktopH = H - TB_H

local hDesktop = syscall("gdi_create_surface", W, nDesktopH, {
    bVisible = true, nScreenX = 1, nScreenY = 1,
    nZOrder = 0, sLabel = "Desktop", bDraggable = false,
})
local hTaskbar = syscall("gdi_create_surface", W, TB_H, {
    bVisible = true, nScreenX = 1, nScreenY = H,
    nZOrder = 9999, sLabel = "Taskbar", bDraggable = false,
})

if not hDesktop or not hTaskbar then return end
syscall("gdi_set_focus", hDesktop)

-- Taskbar Icons 

local tTbIcons = {
    { label = " [=] ", action = "menu",     fg = C_ACCENT,  bg = C_TB_BG, tip = "Menu" },
    { label = " >_ ",  action = "terminal", fg = 0x55FF55,  bg = C_ICON_BG, tip = "Terminal" },
}

do
    local nX = 1
    for _, ic in ipairs(tTbIcons) do ic.x = nX; ic.w = #ic.label; nX = nX + ic.w + 1 end
end

-- Start Menu 

local C_MENU_BG     = 0x111133
local C_MENU_FG     = 0xCCCCDD
local C_MENU_BORDER = 0x3A3A5E
local C_MENU_SEP    = 0x2A2A4E
local C_MENU_HL_BG  = 0x222266

local tMenuItems = {
    { label = " >_ Terminal",   action = "terminal",  fg = 0x55FF55 },
    { label = " *  Settings",   action = "settings",  fg = 0xAAAADD },
    { sep = true },
    { label = "    System Info", action = "sysinfo" },
    { label = "    Processes",   action = "tasks" },
    { sep = true },
    { label = "    Logout",      action = "logout" },
    { label = "    Reboot",      action = "reboot" },
    { label = "    Shutdown",    action = "shutdown" },
}

local MENU_W = 22
local MENU_H = #tMenuItems + 2  -- +2 for top/bottom border
local bMenuOpen = false
local hMenu = nil

-- Create menu surface (hidden initially)
hMenu = syscall("gdi_create_surface", MENU_W, MENU_H, {
    bVisible = false,
    nScreenX = 1,
    nScreenY = H - TB_H - MENU_H,
    nZOrder = 9998,
    sLabel = "StartMenu",
    bDraggable = false,
})

local function renderMenu()
    if not hMenu then return end
    syscall("gdi_surface_fill", hMenu, 1, 1, MENU_W, MENU_H, " ", C_MENU_FG, C_MENU_BG)
    -- Border
    local sHor = "+" .. string.rep("-", MENU_W - 2) .. "+"
    syscall("gdi_surface_set", hMenu, 1, 1, sHor, C_MENU_BORDER, C_MENU_BG)
    syscall("gdi_surface_set", hMenu, 1, MENU_H, sHor, C_MENU_BORDER, C_MENU_BG)
    for y = 2, MENU_H - 1 do
        syscall("gdi_surface_set", hMenu, 1, y, "|", C_MENU_BORDER, C_MENU_BG)
        syscall("gdi_surface_set", hMenu, MENU_W, y, "|", C_MENU_BORDER, C_MENU_BG)
    end
    -- Title
    syscall("gdi_surface_set", hMenu, 3, 1, " AxisOS ", C_ACCENT, C_MENU_BG)
    -- Items
    local nY = 2
    for _, item in ipairs(tMenuItems) do
        if item.sep then
            syscall("gdi_surface_set", hMenu, 1, nY,
                "|" .. string.rep("-", MENU_W - 2) .. "|", C_MENU_SEP, C_MENU_BG)
        else
            local sL = item.label
            if #sL < MENU_W - 4 then sL = sL .. string.rep(" ", MENU_W - 4 - #sL) end
            syscall("gdi_surface_set", hMenu, 3, nY, sL, item.fg or C_MENU_FG, C_MENU_BG)
        end
        nY = nY + 1
    end
end

local function toggleMenu()
    bMenuOpen = not bMenuOpen
    if bMenuOpen then
        renderMenu()
        syscall("gdi_surface_set_visible", hMenu, true)
        syscall("gdi_surface_bring_to_front", hMenu)
        syscall("gdi_set_focus", hMenu)
    else
        syscall("gdi_surface_set_visible", hMenu, false)
        syscall("gdi_set_focus", hDesktop)
    end
    syscall("gdi_composite")
end

local function closeMenu()
    if bMenuOpen then
        bMenuOpen = false
        syscall("gdi_surface_set_visible", hMenu, false)
        syscall("gdi_set_focus", hDesktop)
        syscall("gdi_composite")
    end
end

-- Render 

local function renderDesktop()
    syscall("gdi_surface_fill", hDesktop, 1, 1, W, nDesktopH, " ", C_FG, C_BG)
    syscall("gdi_surface_set", hDesktop, 2, 1,
        "AxisOS  " .. sUser .. "@" .. sHost, C_DIM, C_BG)
    syscall("gdi_surface_set", hDesktop, 2, nDesktopH,
        "Click [=] for start menu.  Drag windows by title bar.", C_DIM, C_BG)
end

local function getClock()
    local nUp = computer.uptime()
    return string.format("%02d:%02d:%02d",
        math.floor(nUp / 3600) % 24, math.floor(nUp / 60) % 60, math.floor(nUp) % 60)
end

local function renderTaskbar()
    syscall("gdi_surface_fill", hTaskbar, 1, 1, W, TB_H, " ", C_TB_FG, C_TB_BG)
    for _, ic in ipairs(tTbIcons) do
        syscall("gdi_surface_set", hTaskbar, ic.x, 1, ic.label, ic.fg, ic.bg)
    end
    -- Window list
    local nWX = tTbIcons[#tTbIcons].x + tTbIcons[#tTbIcons].w + 2
    local tSurf = syscall("gdi_get_surface_list") or {}
    for _, tS in ipairs(tSurf) do
        local sL = tS.sLabel or ""
        if sL ~= "Desktop" and sL ~= "Taskbar" and sL ~= "DM_Login"
           and sL ~= "StartMenu" and tS.bVisible then
            local sE = " " .. sL:sub(1, 10) .. " "
            if nWX + #sE < W - 12 then
                local bFoc = (syscall("gdi_get_focus") == tS.nHandle)
                syscall("gdi_surface_set", hTaskbar, nWX, 1, sE,
                    bFoc and C_TB_SEL or C_TB_FG, C_TB_BG)
                nWX = nWX + #sE + 1
            end
        end
    end
    local sClock = " " .. getClock() .. " "
    syscall("gdi_surface_set", hTaskbar, W - #sClock + 1, 1, sClock, C_CLOCK, C_TB_BG)
    local sU = " " .. sUser .. " "
    syscall("gdi_surface_set", hTaskbar, W - #sClock - #sU + 1, 1, sU, C_DIM, C_TB_BG)
end

-- App Launching 

local function launchTerminal()
    oSys.spawn("/system/apps/terminal.lua", 3, {
        USER = sUser, UID = nUid, HOME = sHome,
        PWD = sHome, PATH = "/usr/commands", HOSTNAME = sHost,
    })
end

local function handleMenuAction(sAction)
    closeMenu()
    if sAction == "terminal" then
        launchTerminal()
    elseif sAction == "logout" then
        bRunning = false
    elseif sAction == "reboot" then
        syscall("computer_reboot")
    elseif sAction == "shutdown" then
        syscall("computer_shutdown")
    elseif sAction == "sysinfo" then
        -- Future: system info app
    elseif sAction == "tasks" then
        -- Future: task manager
    elseif sAction == "settings" then
        -- Future: settings app
    end
end

local function handleIconClick(sAction)
    if sAction == "terminal" then launchTerminal()
    elseif sAction == "menu" then toggleMenu()
    end
end

local function taskbarHitTest(nX)
    for _, ic in ipairs(tTbIcons) do
        if nX >= ic.x and nX < ic.x + ic.w then return ic.action end
    end
    return nil
end

local function menuHitTest(nLocalY)
    local nIdx = nLocalY - 1  -- row 1 = border, row 2 = first item
    if nIdx < 1 or nIdx > #tMenuItems then return nil end
    local item = tMenuItems[nIdx]
    if item.sep then return nil end
    return item.action
end

-- Main Loop 

bRunning = true
local nLastClock = 0

renderDesktop()
renderTaskbar()
syscall("gdi_composite")

while bRunning do
    local evt = nil
    local evtSrc = nil

    -- Poll surfaces for events (menu first when open, so it gets priority)
    if bMenuOpen and hMenu then
        local e = syscall("gdi_pop_input", hMenu)
        if e then evt = e; evtSrc = "menu" end
    end
    if not evt then
        local e = syscall("gdi_pop_input", hTaskbar)
        if e then evt = e; evtSrc = "taskbar" end
    end
    if not evt then
        local e = syscall("gdi_pop_input", hDesktop)
        if e then evt = e; evtSrc = "desktop" end
    end

    if evt then
        if evt.sType == "key_down" then
            local ch = evt.nChar or 0
            if ch == 12 then bRunning = false end  -- Ctrl+L
            if ch == 27 and bMenuOpen then closeMenu() end  -- Esc
        elseif evt.sType == "touch" then
            if evtSrc == "menu" then
                local sAction = menuHitTest(evt.nY)
                if sAction then handleMenuAction(sAction) end
            elseif evtSrc == "taskbar" then
                local sAction = taskbarHitTest(evt.nX)
                if sAction then handleIconClick(sAction) end
            elseif evtSrc == "desktop" then
                if bMenuOpen then closeMenu() end
            end
        end
    else
        syscall("process_yield")
    end

    -- Refresh clock every second
    local nNow = computer.uptime()
    if nNow - nLastClock >= 1.0 then
        nLastClock = nNow
        renderTaskbar()
        syscall("gdi_composite")
    end
end

syscall("gdi_destroy_surface", hDesktop)
syscall("gdi_destroy_surface", hTaskbar)
if hMenu then syscall("gdi_destroy_surface", hMenu) end