-- /drivers/screen.sys.lua - Stub Driver
-- note: the screen component is currently managed directly by the TTY and GPU drivers.
-- this stub just satisfies the loader for now.
local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

g_tDriverInfo = { sDriverName = "AxisScreenStub", sDriverType = tDKStructs.DRIVER_TYPE_KMD, nLoadPriority = 200, bAsyncIoSupported = true }

function DriverEntry(pDriverObject)
  oKMD.DkPrint("Screen Stub Driver loaded. GPU/TTY drivers are in control.")
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