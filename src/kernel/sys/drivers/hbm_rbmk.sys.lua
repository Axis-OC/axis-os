--
-- /sys/drivers/hbm_rbmk.sys.lua
-- KCMD Driver for HBM Nuclear Tech Mod — RBMK Reactor Components
--
-- Creates /dev/hbm_rbmk — singleton device.
-- Discovers and caches all RBMK OC component proxies.
-- Provides device_control IPC for all RBMK operations.
--

local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

g_tDriverInfo = {
    sDriverName    = "HBM_RBMK",
    sDriverType    = tDKStructs.DRIVER_TYPE_KMD,
    nLoadPriority  = 400,
    sVersion       = "1.0.0",
}

local g_pDeviceObject = nil

-- Component type → OC name mapping
local COMP_TYPES = {
    "rbmk_console",
    "rbmk_crane",
    "rbmk_fuel_rod",
    "rbmk_control_rod",
    "rbmk_boiler",
    "rbmk_heater",
    "rbmk_cooler",
    "rbmk_outgasser",
}

-- Cached component proxies: {[type] = {[addr] = proxy, ...}}
local g_tComps = {}
local g_tFirst = {}

-- =============================================
-- COMPONENT DISCOVERY
-- =============================================

local function scanAll()
    g_tComps = {}
    g_tFirst = {}
    for _, sType in ipairs(COMP_TYPES) do
        g_tComps[sType] = {}
        local bOk, tList = syscall("raw_component_list", sType)
        if bOk and tList then
            local bFirst = true
            for addr in pairs(tList) do
                local pOk, proxy = pcall(function()
                    local _, p = oKMD.DkGetHardwareProxy(addr)
                    return p
                end)
                if pOk and proxy then
                    g_tComps[sType][addr] = proxy
                    if bFirst then
                        g_tFirst[sType] = addr
                        bFirst = false
                    end
                end
            end
        end
    end
end

local function getProxy(sType, sAddr)
    if not g_tComps[sType] then return nil end
    if sAddr then return g_tComps[sType][sAddr] end
    local sFirst = g_tFirst[sType]
    if sFirst then return g_tComps[sType][sFirst], sFirst end
    return nil
end

local function safeInvoke(proxy, sMethod, ...)
    if not proxy then return nil, "no component" end
    if not proxy[sMethod] then return nil, "no method: " .. tostring(sMethod) end
    local bOk, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12 =
        pcall(proxy[sMethod], ...)
    if not bOk then return nil, tostring(r1) end
    return r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12
end

-- =============================================
-- IRP HANDLERS
-- =============================================

local function fCreate(d, i)
    oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS)
end

local function fClose(d, i)
    oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS)
end

local function fDeviceControl(d, i)
    local sMethod = i.tParameters.sMethod
    local tArgs   = i.tParameters.tArgs or {}

    -- ── Discovery ──

    if sMethod == "scan" then
        scanAll()
        local nTotal = 0
        for _, tByAddr in pairs(g_tComps) do
            for _ in pairs(tByAddr) do nTotal = nTotal + 1 end
        end
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, nTotal)
        return

    elseif sMethod == "list" then
        local tResult = {}
        for sType, tByAddr in pairs(g_tComps) do
            for addr in pairs(tByAddr) do
                tResult[#tResult + 1] = {type = sType, address = addr}
            end
        end
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, tResult)
        return

    elseif sMethod == "list_type" then
        local sType = tArgs[1]
        if not g_tComps[sType] then
            oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, {})
            return
        end
        local tResult = {}
        for addr in pairs(g_tComps[sType]) do
            tResult[#tResult + 1] = addr
        end
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, tResult)
        return

    elseif sMethod == "first" then
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, g_tFirst[tArgs[1]])
        return

    -- ── Console Operations ──

    elseif sMethod == "console_column" then
        local proxy = getProxy("rbmk_console", tArgs[3])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        local r = safeInvoke(proxy, "getColumnData", tArgs[1], tArgs[2])
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, r)
        return

    elseif sMethod == "console_grid" then
        local proxy = getProxy("rbmk_console", tArgs[1])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        local tGrid = {}
        for gx = 0, 14 do
            for gy = 0, 14 do
                local r = safeInvoke(proxy, "getColumnData", gx, gy)
                if r then r._gx = gx; r._gy = gy; tGrid[#tGrid + 1] = r end
            end
        end
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, tGrid)
        return

    elseif sMethod == "console_pos" then
        local proxy = getProxy("rbmk_console", tArgs[1])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, safeInvoke(proxy, "getRBMKPos"))
        return

    elseif sMethod == "console_set_level" then
        local proxy = getProxy("rbmk_console", tArgs[2])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, safeInvoke(proxy, "setLevel", tArgs[1]))
        return

    elseif sMethod == "console_set_column_level" then
        local proxy = getProxy("rbmk_console", tArgs[4])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS,
            safeInvoke(proxy, "setColumnLevel", tArgs[1], tArgs[2], tArgs[3]))
        return

    elseif sMethod == "console_set_color_level" then
        local proxy = getProxy("rbmk_console", tArgs[3])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS,
            safeInvoke(proxy, "setColorLevel", tArgs[1], tArgs[2]))
        return

    elseif sMethod == "console_set_color" then
        local proxy = getProxy("rbmk_console", tArgs[4])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS,
            safeInvoke(proxy, "setColor", tArgs[1], tArgs[2], tArgs[3]))
        return

    elseif sMethod == "console_az5" then
        local proxy = getProxy("rbmk_console", tArgs[1])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, safeInvoke(proxy, "pressAZ5"))
        return

    -- ── Crane Operations ──

    elseif sMethod == "crane_move" then
        local proxy = getProxy("rbmk_crane", tArgs[2])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, safeInvoke(proxy, "move", tArgs[1]))
        return

    elseif sMethod == "crane_load" then
        local proxy = getProxy("rbmk_crane", tArgs[1])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, safeInvoke(proxy, "load"))
        return

    elseif sMethod == "crane_pos" then
        local proxy = getProxy("rbmk_crane", tArgs[1])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, safeInvoke(proxy, "getCranePos"))
        return

    elseif sMethod == "crane_depletion" then
        local proxy = getProxy("rbmk_crane", tArgs[1])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, safeInvoke(proxy, "getDepletion"))
        return

    elseif sMethod == "crane_xenon" then
        local proxy = getProxy("rbmk_crane", tArgs[1])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, safeInvoke(proxy, "getXenonPoison"))
        return

    -- ── Generic Component Invoke ──

    elseif sMethod == "comp_invoke" then
        local sType = tArgs[1]
        local sMeth = tArgs[2]
        local sAddr = tArgs[3]
        local proxy = getProxy(sType, sAddr)
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        local tCallArgs = {}
        for k = 4, #tArgs do tCallArgs[#tCallArgs + 1] = tArgs[k] end
        local bOk, r1, r2, r3, r4, r5, r6 = pcall(proxy[sMeth], table.unpack(tCallArgs))
        if not bOk then
            oKMD.DkCompleteRequest(i, tStatus.STATUS_UNSUCCESSFUL, tostring(r1))
            return
        end
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, r1)
        return

    -- ── Shorthand Info Queries ──

    elseif sMethod == "fuel_info" then
        local proxy = getProxy("rbmk_fuel_rod", tArgs[1])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        local r = {safeInvoke(proxy, "getInfo")}
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, {
            heat=r[1], skinHeat=r[2], coreHeat=r[3], flux=r[4],
            fluxRatio=r[5], enrichment=r[6], xenon=r[7], rodType=r[8],
            moderated=r[9], x=r[10], y=r[11], z=r[12],
        })
        return

    elseif sMethod == "control_info" then
        local proxy = getProxy("rbmk_control_rod", tArgs[1])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        local r = {safeInvoke(proxy, "getInfo")}
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, {
            heat=r[1], level=r[2], targetLevel=r[3], x=r[4], y=r[5], z=r[6],
        })
        return

    elseif sMethod == "control_set_level" then
        local proxy = getProxy("rbmk_control_rod", tArgs[2])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        safeInvoke(proxy, "setLevel", tArgs[1])
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS)
        return

    elseif sMethod == "boiler_info" then
        local proxy = getProxy("rbmk_boiler", tArgs[1])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        local r = {safeInvoke(proxy, "getInfo")}
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, {
            heat=r[1], steam=r[2], steamMax=r[3], water=r[4],
            waterMax=r[5], steamType=r[6], x=r[7], y=r[8], z=r[9],
        })
        return

    elseif sMethod == "boiler_set_steam_type" then
        local proxy = getProxy("rbmk_boiler", tArgs[2])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        safeInvoke(proxy, "setSteamType", tArgs[1])
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS)
        return

    elseif sMethod == "heater_info" then
        local proxy = getProxy("rbmk_heater", tArgs[1])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        local r = {safeInvoke(proxy, "getInfo")}
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, {
            heat=r[1], coolant=r[2], coolantMax=r[3], hot=r[4],
            hotMax=r[5], coldType=r[6], hotType=r[7], x=r[8], y=r[9], z=r[10],
        })
        return

    elseif sMethod == "cooler_info" then
        local proxy = getProxy("rbmk_cooler", tArgs[1])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        local r = {safeInvoke(proxy, "getInfo")}
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, {
            heat=r[1], cryo=r[2], cryoMax=r[3], x=r[4], y=r[5], z=r[6],
        })
        return

    elseif sMethod == "outgasser_info" then
        local proxy = getProxy("rbmk_outgasser", tArgs[1])
        if not proxy then oKMD.DkCompleteRequest(i, tStatus.STATUS_NO_SUCH_DEVICE); return end
        local r = {safeInvoke(proxy, "getInfo")}
        oKMD.DkCompleteRequest(i, tStatus.STATUS_SUCCESS, {
            gas=r[1], gasMax=r[2], progress=r[3], gasTypeId=r[4],
            x=r[5], y=r[6], z=r[7], craftName=r[8], craftCount=r[9],
        })
        return

    else
        oKMD.DkCompleteRequest(i, tStatus.STATUS_NOT_IMPLEMENTED)
    end
end

-- =============================================
-- DRIVER ENTRY / UNLOAD
-- =============================================

function DriverEntry(pDriverObject)
    oKMD.DkPrint("HBM_RBMK: Initializing...")

    pDriverObject.tDispatch[tDKStructs.IRP_MJ_CREATE]         = fCreate
    pDriverObject.tDispatch[tDKStructs.IRP_MJ_CLOSE]          = fClose
    pDriverObject.tDispatch[tDKStructs.IRP_MJ_DEVICE_CONTROL] = fDeviceControl

    local nSt, pDevObj = oKMD.DkCreateDevice(pDriverObject, "\\Device\\HbmRbmk")
    if nSt ~= tStatus.STATUS_SUCCESS then
        oKMD.DkPrint("HBM_RBMK: Failed to create device!")
        return nSt
    end
    g_pDeviceObject = pDevObj

    oKMD.DkCreateSymbolicLink("/dev/hbm_rbmk", "\\Device\\HbmRbmk")

    -- Initial component scan
    scanAll()
    local nTotal = 0
    for _, tByAddr in pairs(g_tComps) do
        for _ in pairs(tByAddr) do nTotal = nTotal + 1 end
    end
    oKMD.DkPrint("HBM_RBMK: Found " .. nTotal .. " RBMK component(s)")

    return tStatus.STATUS_SUCCESS
end

function DriverUnload(pDriverObject)
    oKMD.DkDeleteSymbolicLink("/dev/hbm_rbmk")
    oKMD.DkDeleteDevice(g_pDeviceObject)
    return tStatus.STATUS_SUCCESS
end

-- =============================================
-- MAIN DRIVER LOOP (REQUIRED — without this, DKMS deadlocks)
-- =============================================

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