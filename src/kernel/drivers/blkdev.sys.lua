--
-- /drivers/blkdev.sys.lua
-- CMD driver for unmanaged OC 'drive' components
--
local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

g_tDriverInfo = {
  sDriverName = "AxisBlockDev",
  sDriverType = tDKStructs.DRIVER_TYPE_CMD,
  nLoadPriority = 300,
  sVersion = "1.0.0",
  sSupportedComponent = "drive",
}

local g_pDev = nil
local g_oProxy = nil

local function fCreate(d,i) oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS) end
local function fClose(d,i) oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS) end

local function fCtl(d, i)
  local m = i.tParameters.sMethod
  local a = i.tParameters.tArgs or {}
  if not g_oProxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_DEVICE_NOT_READY); return end

  if m == "info" then
    local ss = g_oProxy.getSectorSize()
    oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, {
      sectorSize = ss,
      capacity = g_oProxy.getCapacity(),
      platters = g_oProxy.getPlatterCount(),
      sectorCount = math.floor(g_oProxy.getCapacity() / ss),
    })
  elseif m == "read_sector" then
    local n = a[1]; if not n then oKMD.DkCompleteRequest(i, tStatus.STATUS_INVALID_PARAMETER); return end
    local ok, d2 = pcall(g_oProxy.readSector, n)
    if ok then oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, d2)
    else oKMD.DkCompleteRequest(i, tStatus.STATUS_UNSUCCESSFUL, d2) end
  elseif m == "write_sector" then
    local n, sd = a[1], a[2]
    if not n or not sd then oKMD.DkCompleteRequest(i, tStatus.STATUS_INVALID_PARAMETER); return end
    local ok, e = pcall(g_oProxy.writeSector, n, sd)
    if ok then oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS)
    else oKMD.DkCompleteRequest(i, tStatus.STATUS_UNSUCCESSFUL, e) end
  elseif m == "batch_read" then
    local t = a[1]; if not t then oKMD.DkCompleteRequest(i, tStatus.STATUS_INVALID_PARAMETER); return end
    local r = {}; for _, n in ipairs(t) do
      local ok, d2 = pcall(g_oProxy.readSector, n); r[#r+1] = ok and d2 or false
    end
    oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, r)
  elseif m == "batch_write" then
    local t = a[1]; if not t then oKMD.DkCompleteRequest(i, tStatus.STATUS_INVALID_PARAMETER); return end
    local n = 0; for _, op in ipairs(t) do
      if pcall(g_oProxy.writeSector, op[1], op[2]) then n = n + 1 end
    end
    oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, n)
  else
    oKMD.DkCompleteRequest(i, tStatus.STATUS_NOT_IMPLEMENTED)
  end
end

function DriverEntry(pDO)
  oKMD.DkPrint("AxisBlockDev: Init")
  pDO.tDispatch[tDKStructs.IRP_MJ_CREATE] = fCreate
  pDO.tDispatch[tDKStructs.IRP_MJ_CLOSE] = fClose
  pDO.tDispatch[tDKStructs.IRP_MJ_DEVICE_CONTROL] = fCtl

  -- FIX: kmd_api is cached from the first process that loaded it (e.g. TTY).
  -- Its internal env reference is bound to that process's sandbox, not ours.
  -- Capture env.address HERE (in our own sandbox) and pass it explicitly,
  -- otherwise DkCreateComponentDevice reads the wrong process's address.
  local addr = env.address
  local st, dev = oKMD.DkCreateComponentDevice(pDO, "drive", addr)
  if st ~= tStatus.STATUS_SUCCESS then return st end
  g_pDev = dev

  local ps, p = oKMD.DkGetHardwareProxy(addr)
  if ps ~= tStatus.STATUS_SUCCESS then return ps end
  g_oProxy = p

  local ss = p.getSectorSize()
  local cap = p.getCapacity()
  oKMD.DkPrint(string.format("AxisBlockDev: %dKB, %d-byte sectors", cap/1024, ss))
  return tStatus.STATUS_SUCCESS
end

function DriverUnload(pDO)
  if g_pDev and g_pDev.pDeviceExtension.sAutoSymlink then
    oKMD.DkDeleteSymbolicLink(g_pDev.pDeviceExtension.sAutoSymlink)
  end
  oKMD.DkDeleteDevice(g_pDev)
  return tStatus.STATUS_SUCCESS
end

while true do
  local b, pid, sig, p1, p2 = syscall("signal_pull")
  if b then
    if sig == "driver_init" then
      p1.fDriverUnload = DriverUnload
      local st = DriverEntry(p1)
      syscall("signal_send", pid, "driver_init_complete", st, p1)
    elseif sig == "irp_dispatch" then
      p2(g_pDev, p1)
    end
  end
end