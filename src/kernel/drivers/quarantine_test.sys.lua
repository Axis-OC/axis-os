--
-- /drivers/quarantine_test.sys.lua
-- Deliberately faulty driver — triggers HVCI quarantine protection.
--
-- After initialization, corrupts its own dispatch table so that
-- every IRP dispatch crashes in DKMS context. Three crashes within
-- 60 seconds triggers automatic driver quarantine.
--
-- Load with:  insmod /drivers/quarantine_test.sys.lua
-- Test with:  qtest
--

local tStatus    = require("errcheck")
local oKMD       = require("kmd_api")
local tDKStructs = require("shared_structs")

-- ── Driver info (must pass dkms_sec validation) ──

g_tDriverInfo = {
    sDriverName       = "QuarantineTester",
    sDriverType       = tDKStructs.DRIVER_TYPE_KMD,
    nLoadPriority     = 999,
    sVersion          = "1.0.0",
    bAsyncIoSupported = true,
}

local g_pDeviceObject = nil

-- ── IRP handlers (exist to pass init validation; never actually called) ──

local function fCreate(pDev, pIrp)
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

local function fClose(pDev, pIrp)
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

local function fDevCtl(pDev, pIrp)
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

-- ── Driver entry ──

function DriverEntry(pDriverObject)
    oKMD.DkPrint("QuarantineTester: initializing...")

    pDriverObject.tDispatch[tDKStructs.IRP_MJ_CREATE]         = fCreate
    pDriverObject.tDispatch[tDKStructs.IRP_MJ_CLOSE]          = fClose
    pDriverObject.tDispatch[tDKStructs.IRP_MJ_DEVICE_CONTROL] = fDevCtl

    -- Create device using /dev/ path directly so DKMS can find it
    -- in g_tDeviceTree when IRPs arrive (IO manager passes /dev/
    -- paths unchanged for devices without a special mapping).
    local nSt, pDev = oKMD.DkCreateDevice(pDriverObject, "/dev/qtest")
    if nSt ~= tStatus.STATUS_SUCCESS then
        oKMD.DkPrint("QuarantineTester: device creation failed")
        return nSt
    end
    g_pDeviceObject = pDev

    -- Also register symlink so the device appears in `ls /dev`
    oKMD.DkCreateSymbolicLink("/dev/qtest", "/dev/qtest")

    oKMD.DkPrint("QuarantineTester: /dev/qtest created — driver ready")
    return tStatus.STATUS_SUCCESS
end

function DriverUnload(pDriverObject)
    oKMD.DkDeleteSymbolicLink("/dev/qtest")
    if g_pDeviceObject then oKMD.DkDeleteDevice(g_pDeviceObject) end
    return tStatus.STATUS_SUCCESS
end

-- ── Main loop ──

while true do
    local bOk, nSender, sSig, p1, p2 = syscall("signal_pull")
    if bOk then
        if sSig == "driver_init" then
            local pDO = p1
            pDO.fDriverUnload = DriverUnload
            local nStatus = DriverEntry(pDO)

            -- Complete the init handshake with DKMS
            syscall("signal_send", nSender, "driver_init_complete", nStatus, pDO)

            -- ═══════════════════════════════════════════
            -- DELIBERATE CORRUPTION
            --
            -- Replace the dispatch table with `false`.
            -- When DKMS dispatches the next IRP, it runs:
            --
            --   fHandler = pDriverObject.tDispatch[nMaj]
            --             = false[0x00]
            --
            -- This throws "attempt to index a boolean value",
            -- caught by DKMS's pcall → fRecordDriverFault().
            -- Three faults in 60s → QUARANTINED.
            -- ═══════════════════════════════════════════
            if nStatus == tStatus.STATUS_SUCCESS then
                pDO.tDispatch = false
                oKMD.DkPrint("QuarantineTester: dispatch table corrupted — fault injection active")
            end

        elseif sSig == "irp_dispatch" then
            -- Unreachable: DKMS crashes before the signal is sent
            local fHandler = p2
            if fHandler then fHandler(g_pDeviceObject, p1) end
        end
    end
end