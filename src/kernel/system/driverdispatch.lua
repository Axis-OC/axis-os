--
-- /system/driverdispatch.lua
-- v3: Walks device stack (filter → function driver)
--

local tStatus = require("errcheck")
local tDKStructs = require("shared_structs")
local oDispatch = {}

function oDispatch.DispatchIrp(pIrp, g_tDeviceTree, g_tSymbolicLinks)
  local sName = pIrp.sDeviceName
  local pDeviceObject = g_tDeviceTree[sName]

  -- Resolve symlinks
  if not pDeviceObject and g_tSymbolicLinks then
    local sResolved = g_tSymbolicLinks[sName]
    if sResolved then
      pDeviceObject = g_tDeviceTree[sResolved]
      if pDeviceObject then pIrp.sDeviceName = sResolved; sName = sResolved end
    end
  end

  if not pDeviceObject then return tStatus.STATUS_NO_SUCH_DEVICE end

  -- Walk to the TOP of the device stack
  local pTopDevice = tDKStructs.fGetTopOfStack(pDeviceObject)
  local pTargetDevice = pTopDevice or pDeviceObject

  local pDriverObject = pTargetDevice.pDriverObject
  if not pDriverObject then return tStatus.STATUS_INVALID_DRIVER_OBJECT end

  local fHandler = pDriverObject.tDispatch[pIrp.nMajorFunction]
  if not fHandler then
    -- If filter has no handler, pass down the stack
    if pTargetDevice.pLowerDevice then
      pTargetDevice = pTargetDevice.pLowerDevice
      pDriverObject = pTargetDevice.pDriverObject
      if pDriverObject then
        fHandler = pDriverObject.tDispatch[pIrp.nMajorFunction]
      end
    end
    if not fHandler then return tStatus.STATUS_NOT_IMPLEMENTED end
  end

  -- Track current device in IRP for completion routing
  pIrp.pCurrentDevice = pTargetDevice

  syscall("signal_send", pDriverObject.nDriverPid, "irp_dispatch", pIrp, fHandler)
  return tStatus.STATUS_PENDING
end

-- NEW: Pass IRP down the device stack (called by filter drivers)
function oDispatch.IoCallDriver(pLowerDevice, pIrp)
    if not pLowerDevice then return tStatus.STATUS_NO_SUCH_DEVICE end
    local pDriverObject = pLowerDevice.pDriverObject
    if not pDriverObject then return tStatus.STATUS_INVALID_DRIVER_OBJECT end
    local fHandler = pDriverObject.tDispatch[pIrp.nMajorFunction]
    if not fHandler then return tStatus.STATUS_NOT_IMPLEMENTED end
    pIrp.pCurrentDevice = pLowerDevice
    syscall("signal_send", pDriverObject.nDriverPid, "irp_dispatch", pIrp, fHandler)
    return tStatus.STATUS_PENDING
end

return oDispatch