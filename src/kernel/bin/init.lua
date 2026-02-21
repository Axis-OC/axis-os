--
-- /bin/init.lua
-- Paranoid Mode
--
local oFs = require("filesystem")
local oSys = require("syscall")

local hStdin = oFs.open("/dev/tty", "r")
local hStdout = oFs.open("/dev/tty", "w")

if not hStdin or not hStdout then
  syscall("kernel_log", "[INIT] FATAL: Could not open /dev/tty!")
end

local function readFileSimple(sPath)
  local h = oFs.open(sPath, "r")
  if not h then return nil end
  local d = oFs.read(h, math.huge)
  oFs.close(h)
  if type(d) ~= "string" then return nil end
  return d:gsub("\n", "")
end

local sHostname = readFileSimple("/etc/hostname") or "localhost"

local function fHash(sPassword)
  return string.reverse(sPassword) .. "AURA_SALT"
end

local tPasswdDb = {}

local function fLoadPasswd()
  local sContent = readFileSimple("/etc/passwd.lua")
  if sContent and #sContent > 0 then
      local f, err = load(sContent, "passwd", "t", {})
      if f then 
         local tResult = f()
         if type(tResult) == "table" then tPasswdDb = tResult end
      end
  end
  if not tPasswdDb or not next(tPasswdDb) then
     tPasswdDb = { root = { hash = fHash("root"), home = "/", shell = "/bin/sh.lua", uid=0 } }
  end
end

fLoadPasswd()

oFs.write(hStdout, "\f")


while true do
  io.write("    _        _          ___   ____  ",
 "   / \\  __ _(_)_______/ _ \\/ ___| ",
 "  / _ \\ \\ \\/ / / __| | | \\___ \\ ",
 " / ___ \\ >  <| \\__ \\ |_| |___) |",
 "/_/   \\_/_/\\_\\_|___/\\___/|____/ ")

  io.write("AxisOS v0.6-HV-beta\n")
  io.write("")
  io.write("\n________________________________________________\n\n")
  io.write("XEN XKA v0.6-HV-beta on " .. sHostname .. "\n\n")
  
  io.write(sHostname .. " login: ")   -- No buffering, appears immediately
  
  local sUsername = oFs.read(hStdin)
  
  if sUsername then
    sUsername = sUsername:gsub("\n", ""):gsub(" ", "")
    
    local tUserEntry = tPasswdDb[sUsername]
    
    io.write("Password: ")             -- No buffering
    
    local sPassword = oFs.read(hStdin) 
    if sPassword then sPassword = sPassword:gsub("\n", "") end

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
      syscall("process_yield")  -- yield instead of wait(0) which does nothing
    end
  else
    syscall("kernel_log", "[INIT] Error reading stdin. Retrying...")
    syscall("process_yield")
  end
end