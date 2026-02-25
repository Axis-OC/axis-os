--
-- /bin/init.lua
-- Paranoid Mode + Display Manager Support
--
local oFs = require("filesystem")
local oSys = require("syscall")

local hStdin = oFs.open("/dev/tty", "r")
local hStdout = oFs.open("/dev/tty", "w")

if not hStdin or not hStdout then
    syscall("kernel_log", "[INIT] FATAL: Could not open /dev/tty!")
end

local function readFileRaw(sPath)
    local h = oFs.open(sPath, "r")
    if not h then
        return nil
    end
    local d = oFs.read(h, math.huge)
    oFs.close(h)
    if type(d) ~= "string" then
        return nil
    end
    return d
end

local sHostnameRaw = readFileRaw("/etc/hostname")
local sHostname = sHostnameRaw and sHostnameRaw:gsub("[%c%s]", "") or "localhost"

local function fHash(sPassword)
    return string.reverse(sPassword) .. "AURA_SALT"
end

local tPasswdDb = {}

local function fLoadPasswd()
    local sContent = readFileRaw("/etc/passwd.lua")
    if sContent and #sContent > 0 then
        local f, err = load(sContent, "passwd", "t", {})
        if f then
            local tResult = f()
            if type(tResult) == "table" then
                tPasswdDb = tResult
            end
        else
            syscall("kernel_log", "[INIT] Parse error in passwd.lua: " .. tostring(err))
        end
    end
    if not tPasswdDb or not next(tPasswdDb) then
        syscall("kernel_log", "[INIT] Using fallback root account")
        tPasswdDb = {
            root = {
                hash = fHash("root"),
                home = "/",
                shell = "/bin/sh.lua",
                uid = 0
            }
        }
    end
end

fLoadPasswd()

-- =============================================
-- CHECK DISPLAY MANAGER CONFIGURATION
-- =============================================

local bDmEnabled = false
local tDmCfg = nil

local sDmCfgRaw = readFileRaw("/etc/dm.cfg")
if sDmCfgRaw and #sDmCfgRaw > 0 then
    local f = load(sDmCfgRaw, "dm.cfg", "t", {})
    if f then
        local bOk, tResult = pcall(f)
        if bOk and type(tResult) == "table" then
            tDmCfg = tResult
            bDmEnabled = (tResult.enabled == true)
        end
    end
end

-- =============================================
-- DISPLAY MANAGER MODE
-- =============================================

if bDmEnabled and tDmCfg then
    syscall("kernel_log", "[INIT] Display Manager mode enabled — launching DM")

    -- Configure multi-GPU if specified
    if tDmCfg.multi_gpu and tDmCfg.multi_gpu.enabled then
        pcall(function()
            syscall("gdi_set_multi_gpu_mode", tDmCfg.multi_gpu)
        end)
    end

    while true do
        pcall(function()
            oFs.deviceControl(hStdin, "set_mode", {"cooked"})
            oFs.deviceControl(hStdin, "set_nonblock", {false})
            oFs.deviceControl(hStdin, "leave_alt_screen", {})
        end)

        -- Launch the display manager
        local nDmPid = oSys.spawn("/system/dm.lua", 3, {
            USER = "root",
            UID = 0,
            HOME = "/root",
            PWD = "/",
            PATH = "/usr/commands",
            HOSTNAME = sHostname,
            DM_CONFIG = tDmCfg,
            PASSWD_DB = tPasswdDb
        })

        if nDmPid then
            oSys.wait(nDmPid)
            -- DM exited — restart it (unless machine is shutting down)
            oFs.write(hStdout, "\f")
        else
            syscall("kernel_log", "[INIT] Failed to spawn display manager, falling back to text mode")
            bDmEnabled = false
            break
        end
    end
end

-- =============================================
-- TEXT MODE LOGIN (classic behavior)
-- =============================================

if not bDmEnabled then
    oFs.write(hStdout, "\f")
    pcall(function()
        oFs.deviceControl(hStdin, "set_mode", {"cooked"})
        oFs.deviceControl(hStdin, "set_nonblock", {false})
        oFs.deviceControl(hStdin, "leave_alt_screen", {})
    end)

    while true do
        io.write("    _        _       ___   ____  \n", "   / \\  __ _(_)_____/ _ \\/ ___| \n",
            "  / _ \\ \\ \\/ / / __| | | \\___ \\ \n", " / ___ \\ >  <| \\__ \\ |_| |___) |\n",
            "/_/   \\_/_/\\_\\_|___/\\___/|____/ \n")

        io.write("AxisOS v0.81-EX-beta\n")
        io.write("\n________________________________________________\n\n")
        io.write("XEN XKA v0.81-EX-beta on " .. sHostname .. "\n\n")

        io.write(sHostname .. " login: ")

        local sUsername = oFs.read(hStdin)

        if sUsername then
            sUsername = sUsername:gsub("[%c%s]", "")

            local tUserEntry = tPasswdDb[sUsername]

            io.write("Password: ")

            local sPassword = oFs.read(hStdin)
            if sPassword then
                sPassword = sPassword:gsub("[%c%s]", "")
            end

            if tUserEntry and tUserEntry.hash == fHash(sPassword or "") then
                io.write("\nAccess Granted.\n")

                local nTargetRing = tUserEntry.ring or 3

                if nTargetRing == 0 then
                    io.write("\27[31mWARNING: SPAWNING IN RING 0 (KERNEL MODE)\27[37m\n")
                end

                local nPid = oSys.spawn(tUserEntry.shell, nTargetRing, {
                    USER = sUsername,
                    UID = tUserEntry.uid,
                    HOME = tUserEntry.home,
                    PWD = tUserEntry.home,
                    PATH = "/usr/commands",
                    HOSTNAME = sHostname
                })

                if nPid then
                    oSys.wait(nPid)
                    io.write("\f")
                end
            else
                io.write("\nLogin incorrect\n")
                syscall("process_yield")
            end
        else
            syscall("kernel_log", "[INIT] Error reading stdin. Retrying...")
            syscall("process_yield")
        end
    end
end
