--
-- /system/dm.lua
-- AxisOS Display Manager — Graphical Login + Session Launcher
--
-- Spawned by init.lua when DM is enabled.
-- Receives: env.DM_CONFIG, env.PASSWD_DB, env.HOSTNAME
--

local oSys = require("syscall")

local tDmCfg   = env.DM_CONFIG  or {}
local tPasswdDb = env.PASSWD_DB  or {}
local sHostname = env.HOSTNAME   or "localhost"

-- =============================================
-- HASH FUNCTION (must match init.lua)
-- =============================================

local function fHash(sPassword)
    return string.reverse(sPassword) .. "AURA_SALT"
end

-- =============================================
-- GPU / SCREEN DISCOVERY
-- =============================================

local nGpuCount = syscall("gdi_get_gpu_count") or 0
if nGpuCount == 0 then
    -- No GPU available — cannot run graphical DM
    syscall("kernel_log", "[DM] No GPU available, exiting.")
    return
end

local tGpuInfo = syscall("gdi_get_gpu_info", tDmCfg.gpu_index or 1)
if not tGpuInfo then
    syscall("kernel_log", "[DM] Cannot get GPU info, exiting.")
    return
end

local W = tGpuInfo.nW or 80
local H = tGpuInfo.nH or 25

-- =============================================
-- COLOR PALETTE
-- =============================================

local C_BG       = tDmCfg.wallpaper_color or 0x0C0C1E
local C_FG       = 0xCCCCDD
local C_ACCENT   = tDmCfg.accent_color or 0x55FFFF
local C_DIM      = 0x555577
local C_INPUT_BG = 0x111133
local C_INPUT_FG = 0xFFFFFF
local C_ERROR    = 0xFF5555
local C_OK       = 0x55FF55
local C_BORDER   = 0x3A3A5E
local C_TITLE_BG = 0x0D2B52

-- =============================================
-- SURFACE CREATION
-- =============================================

local hLoginSurface = syscall("gdi_create_surface", W, H, {
    bVisible   = true,
    nScreenX   = 1,
    nScreenY   = 1,
    nZOrder    = 500,
    sLabel     = "DM_Login",
})

if not hLoginSurface then
    syscall("kernel_log", "[DM] Failed to create login surface.")
    return
end

syscall("gdi_set_focus", hLoginSurface)

-- =============================================
-- DRAWING HELPERS
-- =============================================

local function dmFill(x, y, w, h, ch, fg, bg)
    syscall("gdi_surface_fill", hLoginSurface, x, y, w, h, ch or " ", fg or C_FG, bg or C_BG)
end

local function dmText(x, y, s, fg, bg)
    syscall("gdi_surface_set", hLoginSurface, x, y, s, fg or C_FG, bg or C_BG)
end

local function dmClear()
    dmFill(1, 1, W, H, " ", C_FG, C_BG)
end

local function dmPresent()
    syscall("gdi_composite")
end

local function dmPadText(x, y, w, s, fg, bg)
    if #s > w then s = s:sub(1, w) end
    if #s < w then s = s .. string.rep(" ", w - #s) end
    dmText(x, y, s, fg, bg)
end

-- =============================================
-- LOGO
-- =============================================

local tLogo = {
    "    _        _      ___  ____  ",
    "   / \\  __ _(_)___ / _ \\/ ___| ",
    "  / _ \\ \\ \\/ / / __| | | \\___ \\ ",
    " / ___ \\ >  <| \\__ \\ |_| |___) |",
    "/_/   \\_/_/\\_\\_|___/\\___/|____/ ",
}

-- =============================================
-- RENDER LOGIN SCREEN
-- =============================================

local function renderLoginScreen(sUsername, sPassword, nFocusField, sMessage, nMsgColor)
    dmClear()

    -- Title bar
    dmFill(1, 1, W, 1, " ", 0xFFFFFF, C_TITLE_BG)
    dmText(2, 1, "AxisOS Display Manager", C_ACCENT, C_TITLE_BG)
    dmText(W - 10, 1, sHostname, C_DIM, C_TITLE_BG)

    -- Logo
    local nLogoY = math.max(3, math.floor(H / 2) - 8)
    local nLogoX = math.floor((W - 32) / 2)
    for i, sLine in ipairs(tLogo) do
        dmText(nLogoX, nLogoY + i - 1, sLine, C_DIM)
    end

    -- Version
    dmText(nLogoX, nLogoY + #tLogo + 1, "AxisOS v0.8-GDI-HV-beta", C_DIM)

    -- Login box
    local nBoxW = 38
    local nBoxH = 10
    local nBoxX = math.floor((W - nBoxW) / 2)
    local nBoxY = nLogoY + #tLogo + 3

    -- Box background
    dmFill(nBoxX, nBoxY, nBoxW, nBoxH, " ", C_FG, 0x111122)

    -- Box border
    local sHor = "+" .. string.rep("-", nBoxW - 2) .. "+"
    dmText(nBoxX, nBoxY,             sHor, C_BORDER, 0x111122)
    dmText(nBoxX, nBoxY + nBoxH - 1, sHor, C_BORDER, 0x111122)
    for ry = nBoxY + 1, nBoxY + nBoxH - 2 do
        dmText(nBoxX,             ry, "|", C_BORDER, 0x111122)
        dmText(nBoxX + nBoxW - 1, ry, "|", C_BORDER, 0x111122)
    end

    -- Title
    local sTitle = " Login "
    local nTitleX = nBoxX + math.floor((nBoxW - #sTitle) / 2)
    dmText(nTitleX, nBoxY, sTitle, C_ACCENT, 0x111122)

    -- Username field
    local nFieldW = nBoxW - 8
    local nFieldX = nBoxX + 4
    local nUserY  = nBoxY + 2
    dmText(nBoxX + 2, nUserY, "User:", C_DIM, 0x111122)
    local sUserDisp = sUsername
    if #sUserDisp > nFieldW - 2 then sUserDisp = sUserDisp:sub(-nFieldW + 2) end
    local nUserFieldBg = (nFocusField == 0) and 0x222255 or C_INPUT_BG
    dmText(nFieldX + 6, nUserY, "[", C_DIM, nUserFieldBg)
    dmPadText(nFieldX + 7, nUserY, nFieldW - 2, sUserDisp, C_INPUT_FG, nUserFieldBg)
    dmText(nFieldX + 7 + nFieldW - 2, nUserY, "]", C_DIM, nUserFieldBg)

    -- Cursor in username field
    if nFocusField == 0 then
        local nCurX = nFieldX + 7 + #sUserDisp
        if nCurX < nFieldX + 7 + nFieldW - 2 then
            dmText(nCurX, nUserY, "_", C_ACCENT, nUserFieldBg)
        end
    end

    -- Password field
    local nPassY = nBoxY + 4
    dmText(nBoxX + 2, nPassY, "Pass:", C_DIM, 0x111122)
    local sPassDisp = string.rep("*", math.min(#sPassword, nFieldW - 2))
    local nPassFieldBg = (nFocusField == 1) and 0x222255 or C_INPUT_BG
    dmText(nFieldX + 6, nPassY, "[", C_DIM, nPassFieldBg)
    dmPadText(nFieldX + 7, nPassY, nFieldW - 2, sPassDisp, C_INPUT_FG, nPassFieldBg)
    dmText(nFieldX + 7 + nFieldW - 2, nPassY, "]", C_DIM, nPassFieldBg)

    -- Cursor in password field
    if nFocusField == 1 then
        local nCurX = nFieldX + 7 + #sPassDisp
        if nCurX < nFieldX + 7 + nFieldW - 2 then
            dmText(nCurX, nPassY, "_", C_ACCENT, nPassFieldBg)
        end
    end

    -- Hint
    dmText(nBoxX + 2, nBoxY + 6, "Tab: switch field   Enter: login", C_DIM, 0x111122)

    -- Message
    if sMessage and #sMessage > 0 then
        local nMsgX = nBoxX + math.floor((nBoxW - #sMessage) / 2)
        dmText(nMsgX, nBoxY + nBoxH - 2, sMessage, nMsgColor or C_FG, 0x111122)
    end

    -- Footer
    dmText(2, H, "AxisOS v0.8-GDI-HV-beta on " .. sHostname, C_DIM)

    dmPresent()
end

-- =============================================
-- INPUT HELPERS
-- =============================================

local function pollKey()
    while true do
        local evt = syscall("gdi_pop_input", hLoginSurface)
        if evt and evt.sType == "key_down" then
            return evt.nChar or 0, evt.nCode or 0
        end
        syscall("process_yield")
    end
end

-- =============================================
-- AUTO-LOGIN
-- =============================================

if tDmCfg.auto_login and tDmCfg.auto_login_user then
    local sUser = tDmCfg.auto_login_user
    local tEntry = tPasswdDb[sUser]
    if tEntry then
        syscall("kernel_log", "[DM] Auto-login as: " .. sUser)

        local nDesktopPid = oSys.spawn(tDmCfg.desktop_session or "/system/desktop.lua", 3, {
            USER     = sUser,
            UID      = tEntry.uid,
            HOME     = tEntry.home,
            PWD      = tEntry.home,
            PATH     = "/usr/commands",
            HOSTNAME = sHostname,
            DM_CONFIG = tDmCfg,
        })

        if nDesktopPid then
            oSys.wait(nDesktopPid)
        end

        syscall("gdi_destroy_surface", hLoginSurface)
        return
    end
end

-- =============================================
-- MAIN LOGIN LOOP
-- =============================================

local bRunning = true

while bRunning do
    local sUsername   = ""
    local sPassword   = ""
    local nFocusField = 0   -- 0 = username, 1 = password
    local sMessage    = ""
    local nMsgColor   = C_FG

    renderLoginScreen(sUsername, sPassword, nFocusField, sMessage, nMsgColor)

    local bLoginDone = false

    while not bLoginDone do
        local nCh, nCode = pollKey()

        -- Tab: switch fields
        if nCode == 15 then
            nFocusField = 1 - nFocusField
            sMessage = ""

        -- Enter: attempt login
        elseif nCh == 13 or nCode == 28 then
            if #sUsername == 0 then
                sMessage = "Enter a username"
                nMsgColor = C_ERROR
            else
                local tEntry = tPasswdDb[sUsername]
                if tEntry and tEntry.hash == fHash(sPassword) then
                    sMessage = "Access granted."
                    nMsgColor = C_OK
                    renderLoginScreen(sUsername, sPassword, nFocusField, sMessage, nMsgColor)

                    -- Brief pause so user sees the message
                    syscall("process_yield")
                    syscall("process_yield")

                    -- Hide login surface while desktop runs
                    syscall("gdi_surface_set_visible", hLoginSurface, false)
                    syscall("gdi_composite")

                    -- Spawn desktop session
                    local nDesktopPid = oSys.spawn(
                        tDmCfg.desktop_session or "/system/desktop.lua", 3, {
                            USER     = sUsername,
                            UID      = tEntry.uid,
                            HOME     = tEntry.home,
                            PWD      = tEntry.home,
                            PATH     = "/usr/commands",
                            HOSTNAME = sHostname,
                            DM_CONFIG = tDmCfg,
                        })

                    if nDesktopPid then
                        oSys.wait(nDesktopPid)
                    end

                    -- Desktop exited — show login again
                    syscall("gdi_surface_set_visible", hLoginSurface, true)
                    syscall("gdi_set_focus", hLoginSurface)
                    bLoginDone = true
                else
                    sMessage = "Login incorrect."
                    nMsgColor = C_ERROR
                    sPassword = ""
                    nFocusField = 1
                end
            end

        -- Backspace
        elseif nCh == 8 or nCode == 14 then
            if nFocusField == 0 then
                if #sUsername > 0 then sUsername = sUsername:sub(1, -2) end
            else
                if #sPassword > 0 then sPassword = sPassword:sub(1, -2) end
            end
            sMessage = ""

        -- Escape: power menu
        elseif nCh == 27 or nCode == 1 then
            sMessage = "Press Ctrl+C to shutdown"
            nMsgColor = C_DIM

        -- Ctrl+C: exit DM (returns to init.lua which restarts it or falls back)
        elseif nCh == 3 then
            bRunning = false
            bLoginDone = true

        -- Printable character
        elseif nCh >= 32 and nCh < 127 then
            if nFocusField == 0 then
                if #sUsername < 24 then
                    sUsername = sUsername .. string.char(nCh)
                end
            else
                if #sPassword < 32 then
                    sPassword = sPassword .. string.char(nCh)
                end
            end
            sMessage = ""
        end

        if not bLoginDone then
            renderLoginScreen(sUsername, sPassword, nFocusField, sMessage, nMsgColor)
        end
    end
end

-- =============================================
-- CLEANUP
-- =============================================

syscall("gdi_destroy_surface", hLoginSurface)