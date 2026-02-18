--
-- /system/driverdispatch.lua
-- v2: Resolves VFS symlinks before device tree lookup.
--

local tStatus = require("errcheck")
local oDispatch = {}

function oDispatch.DispatchIrp(pIrp, g_tDeviceTree, g_tSymbolicLinks)
  local sName = pIrp.sDeviceName

  -- 1. Try direct device tree lookup (handles \\Device\\TTY0 etc.)
  local pDeviceObject = g_tDeviceTree[sName]

  -- 2. If not found, try resolving as a VFS symlink (/dev/net → \\Device\\Net0)
  if not pDeviceObject and g_tSymbolicLinks then
    local sResolved = g_tSymbolicLinks[sName]
    if sResolved then
      pDeviceObject = g_tDeviceTree[sResolved]
      if pDeviceObject then
        -- Update the IRP so downstream code sees the real device name
        pIrp.sDeviceName = sResolved
        sName = sResolved
      end
    end
  end

  if not pDeviceObject then
    syscall("kernel_log", "[DD] Error: No device object for '" .. sName ..
            "' (original: " .. pIrp.sDeviceName .. "')")
    return tStatus.STATUS_NO_SUCH_DEVICE
  end

  local pDriverObject = pDeviceObject.pDriverObject
  if not pDriverObject then
    syscall("kernel_log", "[DD] Error: Device '" .. sName .. "' has no driver!")
    return tStatus.STATUS_INVALID_DRIVER_OBJECT
  end

  local fHandler = pDriverObject.tDispatch[pIrp.nMajorFunction]

  if not fHandler then
    return tStatus.STATUS_NOT_IMPLEMENTED
  end

  syscall("signal_send", pDriverObject.nDriverPid, "irp_dispatch", pIrp, fHandler)

  return tStatus.STATUS_PENDING
end

return oDispatch