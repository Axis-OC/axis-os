-- /drivers/keyboard.sys.lua - Stub Driver
-- note: in our current system, keyboard events are raw 'key_down' signals
-- handled directly by the TTY driver. a real keyboard driver would grab these
-- and translate them into a standard input stream.
local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

g_tDriverInfo = { sDriverName = "AxisKeyboardStub", sDriverType = tDKStructs.DRIVER_TYPE_KMD, nLoadPriority = 200, bAsyncIoSupported = true, }

function DriverEntry(pDriverObject)
  oKMD.DkPrint("Keyboard Stub Driver loaded. TTY is still doing all the work.")
  return tStatus.STATUS_SUCCESS
end

function DriverUnload(pDriverObject) return tStatus.STATUS_SUCCESS end

while true do
  local bOk, nSenderPid, sSignalName, p1 = syscall("signal_pull")
  if bOk and sSignalName == "driver_init" then
    local pDriverObject = p1
    pDriverObject.fDriverUnload = DriverUnload
    local nStatus = DriverEntry(pDriverObject)
    syscall("signal_send", nSenderPid, "driver_init_complete", nStatus, pDriverObject)
  end
end