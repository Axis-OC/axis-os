--
-- /drivers/ringfs.sys.lua
-- A circular buffer filesystem driver.
-- It eats text and keeps only the freshest bits.
--

local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

g_tDriverInfo = {
  sDriverName = "AxisRingFS",
  sDriverType = tDKStructs.DRIVER_TYPE_KMD, -- it's a generic utility driver
  nLoadPriority = 400,
  sVersion = "1.0.0",
  bAsyncIoSupported = true,
}

local g_pDeviceObject = nil

-- default size if not specified. 4KB should be enough for anyone, right?
local DEFAULT_BUFFER_SIZE = 4096

-------------------------------------------------
-- IRP HANDLERS
-------------------------------------------------

local function fRingDispatchCreate(pDeviceObject, pIrp)
  -- oKMD.DkPrint("RingFS: Client connected.")
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

local function fRingDispatchClose(pDeviceObject, pIrp)
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

local function fRingDispatchWrite(pDeviceObject, pIrp)
  local sData = pIrp.tParameters.sData
  if not sData then 
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER)
    return 
  end
  
  local pExt = pDeviceObject.pDeviceExtension
  
  -- append new data to the buffer
  pExt.sBuffer = pExt.sBuffer .. tostring(sData)
  
  -- trim the fat if it gets too big
  if #pExt.sBuffer > pExt.nMaxSize then
    -- keep the end of the string
    pExt.sBuffer = string.sub(pExt.sBuffer, -pExt.nMaxSize)
  end
  
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, #sData)
end

local function fRingDispatchRead(pDeviceObject, pIrp)
  local pExt = pDeviceObject.pDeviceExtension
  -- return the whole buffer. simple.
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, pExt.sBuffer)
end

local function fRingDispatchDeviceControl(pDeviceObject, pIrp)
  local sMethod = pIrp.tParameters.sMethod
  local pExt = pDeviceObject.pDeviceExtension
  
  if sMethod == "clear" then
     pExt.sBuffer = ""
     oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
  elseif sMethod == "resize" then
     local nNewSize = tonumber(pIrp.tParameters.tArgs[1])
     if nNewSize and nNewSize > 0 then
        pExt.nMaxSize = nNewSize
        -- trim immediately if needed
        if #pExt.sBuffer > pExt.nMaxSize then
           pExt.sBuffer = string.sub(pExt.sBuffer, -pExt.nMaxSize)
        end
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
     else
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER)
     end
  else
     oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_NOT_IMPLEMENTED)
  end
end

-------------------------------------------------
-- DRIVER ENTRY
-------------------------------------------------

function DriverEntry(pDriverObject)
  oKMD.DkPrint("RingFS: Spinning up the memory donut.")
  
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CREATE] = fRingDispatchCreate
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CLOSE] = fRingDispatchClose
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_WRITE] = fRingDispatchWrite
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_READ] = fRingDispatchRead
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_DEVICE_CONTROL] = fRingDispatchDeviceControl
  
  local nStatus, pDeviceObj = oKMD.DkCreateDevice(pDriverObject, "\\Device\\ringlog")
  if nStatus ~= tStatus.STATUS_SUCCESS then return nStatus end
  g_pDeviceObject = pDeviceObj
  
  -- init the buffer in the extension
  pDeviceObj.pDeviceExtension.sBuffer = ""
  pDeviceObj.pDeviceExtension.nMaxSize = DEFAULT_BUFFER_SIZE
  
  -- create the symlink so users can find us at /dev/ringlog
  oKMD.DkCreateSymbolicLink("/dev/ringlog", "\\Device\\ringlog")
  
  
  return tStatus.STATUS_SUCCESS
end

function DriverUnload(pDriverObject)
  oKMD.DkDeleteSymbolicLink("/dev/ringlog")
  oKMD.DkDeleteDevice(g_pDeviceObject)
  return tStatus.STATUS_SUCCESS
end

-------------------------------------------------
-- MAIN LOOP
-------------------------------------------------
while true do
  local bOk, nSenderPid, sSignalName, p1, p2 = syscall("signal_pull")
  if bOk then
    if sSignalName == "driver_init" then
      local pDriverObject = p1
      pDriverObject.fDriverUnload = DriverUnload
      local nStatus = DriverEntry(pDriverObject)
      syscall("signal_send", nSenderPid, "driver_init_complete", nStatus, pDriverObject)
    elseif sSignalName == "irp_dispatch" then
      local pIrp = p1
      local fHandler = p2
      fHandler(g_pDeviceObject, pIrp)
    end
  end
end