-- /drivers/computer.sys.lua - Stub Driver
local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

g_tDriverInfo = { sDriverName = "AxisComputerStub", sDriverType = tDKStructs.DRIVER_TYPE_KMD, nLoadPriority = 500, bAsyncIoSupported = true, }

function DriverEntry(pDriverObject)
  oKMD.DkPrint("Computer Stub Driver loaded. Exposes... the computer? Sure.")
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