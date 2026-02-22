--
-- /system/lib/dk/kmd_api.lua
--

local fSyscall = syscall
local tStatus = require("errcheck")
local oKMD = require("common_api") 

local function CallDkms(sName, ...)
  local bOk, val1, val2 = fSyscall(sName, ...)
  return val1, val2
end

function oKMD.DkCreateDevice(pDriverObject, sDeviceName)
  oKMD.DkPrint("DkCreateDevice: " .. sDeviceName)
  
  local pDeviceObject, nStatus = CallDkms("dkms_create_device", sDeviceName)
  
  if pDeviceObject then
    return tStatus.STATUS_SUCCESS, pDeviceObject
  else
    return nStatus or tStatus.STATUS_UNSUCCESSFUL, nil
  end
end

function oKMD.DkCreateSymbolicLink(sLinkName, sDeviceName)
  oKMD.DkPrint("SymLink: " .. sLinkName .. " -> " .. sDeviceName)
  local nStatus = CallDkms("dkms_create_symlink", sLinkName, sDeviceName)
  return nStatus
end

function oKMD.DkDeleteDevice(pDeviceObject)
  if not pDeviceObject or type(pDeviceObject) ~= "table" then return tStatus.STATUS_INVALID_PARAMETER end
  local nStatus = CallDkms("dkms_delete_device", pDeviceObject.sDeviceName)
  return nStatus
end

function oKMD.DkDeleteSymbolicLink(sLinkName)
  local nStatus = CallDkms("dkms_delete_symlink", sLinkName)
  return nStatus
end

function oKMD.DkCompleteRequest(pIrp, nStatus, vInformation)
  pIrp.tIoStatus.nStatus = nStatus
  pIrp.tIoStatus.vInformation = vInformation
  fSyscall("dkms_complete_irp", pIrp)
end

function oKMD.DkGetHardwareProxy(sAddress)
    local oProxyOrErr, sErr = fSyscall("raw_component_proxy", sAddress)
    if oProxyOrErr then
        return tStatus.STATUS_SUCCESS, oProxyOrErr
    else
        return tStatus.STATUS_NO_SUCH_DEVICE, sErr
    end
end

function oKMD.DkRegisterInterrupt(sEventName)
    local nStatus = CallDkms("dkms_register_interrupt", sEventName)
    return nStatus
end

-- FIX: Accept sAddress as explicit parameter instead of reading env.address
-- via the module's _ENV (which may be bound to a different process due to
-- global module caching in kernel.custom_require).
function oKMD.DkCreateComponentDevice(pDriverObject, sDeviceTypeName, sAddress)
  -- If address not passed explicitly, try reading from env (may fail
  -- if module was first loaded by a different process)
  if not sAddress then
    local bOk, addr = pcall(function() return env.address end)
    sAddress = bOk and addr or nil
  end

  if not sAddress then
    oKMD.DkPrint("DkCreateComponentDevice: No component address provided!")
    return tStatus.STATUS_INVALID_PARAMETER
  end
  
  local nIndex, _ = CallDkms("dkms_get_next_index", sDeviceTypeName)
  if not nIndex then nIndex = 0 end
  
  local sShortAddr = string.sub(sAddress, 1, 6)
  local sInternalName = string.format("\\Device\\%s_%s", sDeviceTypeName, sShortAddr)
  local sSymlinkName = string.format("/dev/%s_%s_%d", sDeviceTypeName, sShortAddr, nIndex)
  
  oKMD.DkPrint("Auto-creating CMD Device: " .. sSymlinkName)
  
  local nStatus, pDeviceObject = oKMD.DkCreateDevice(pDriverObject, sInternalName)
  if nStatus ~= tStatus.STATUS_SUCCESS then
    return nStatus, nil
  end
  
  nStatus = oKMD.DkCreateSymbolicLink(sSymlinkName, sInternalName)
  if nStatus ~= tStatus.STATUS_SUCCESS then
    oKMD.DkDeleteDevice(pDeviceObject)
    return nStatus, nil
  end
  
  pDeviceObject.pDeviceExtension.sAutoSymlink = sSymlinkName
  
  return tStatus.STATUS_SUCCESS, pDeviceObject
end

return oKMD