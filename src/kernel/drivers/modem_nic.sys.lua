--
-- /drivers/modem_nic.sys.lua
-- AxisOS Modem NIC Driver v2.0 — Full Layer 2 Interface
--
-- Complete rewrite: VLAN tagging, statistics, multi-port,
-- frame encapsulation, configurable MTU, proper interrupt handling.
--

local tStatus    = require("errcheck")
local oKMD       = require("kmd_api")
local tDKStructs = require("shared_structs")

g_tDriverInfo = {
    sDriverName       = "AxisModemNIC",
    sDriverType       = tDKStructs.DRIVER_TYPE_KMD,
    nLoadPriority     = 260,
    sVersion          = "2.0.0",
    bAsyncIoSupported = true,
    capabilities      = {"MODEM_ACCESS", "RAW_COMPONENT_LIST", "RAW_COMPONENT_PROXY"},
}

-- =============================================
-- STATE
-- =============================================

local g_pDeviceObject = nil
local g_oModemProxy   = nil
local g_sModemAddr    = nil
local g_sIfaceName    = "eth0"
local g_nMTU          = 8000       -- OC modem max ~8KB payload
local g_bUp           = true

-- Port allocation
local PORT_IP_STACK   = 1          -- IP traffic (IPv4, ARP)
local PORT_VLAN_CTRL  = 2          -- VLAN control / management
local PORT_DNS        = 53         -- DNS (if running local DNS relay)

-- VLAN configuration
local g_nNativeVlan   = 0          -- 0 = no VLAN (untagged)
local g_tTrunkVlans   = {}         -- {[vid]=true} allowed VLANs in trunk mode
local g_sVlanMode     = "access"   -- "access" | "trunk"

-- Statistics
local g_tStats = {
    nRxPackets    = 0,
    nTxPackets    = 0,
    nRxBytes      = 0,
    nTxBytes      = 0,
    nRxDropped    = 0,
    nTxDropped    = 0,
    nRxErrors     = 0,
    nTxErrors     = 0,
    nRxBroadcast  = 0,
    nTxBroadcast  = 0,
    nVlanTagged   = 0,
    nVlanUntagged = 0,
    nArpRx        = 0,
    nArpTx        = 0,
}

-- Frame type markers (first 2 bytes of modem payload)
local FRAME_IP   = "IP"
local FRAME_ARP  = "AR"
local FRAME_VLAN = "VL"   -- VLAN-tagged frame: VL + 4-byte tag + inner frame

-- RX callback queue (for stack integration)
local g_tRxQueue      = {}
local g_nRxQueueMax   = 64

-- =============================================
-- VLAN TAG ENCODING
-- 802.1Q style: TPID(2) + TCI(2) = PCP(3b) + DEI(1b) + VID(12b)
-- Simplified: we use 4 bytes: "VL" marker + u16(VID)
-- =============================================

local function fPackVlanTag(nVid, nPcp)
    nPcp = nPcp or 0
    -- TCI = (PCP << 13) | (0 << 12) | (VID & 0xFFF)
    local nTci = bit32.bor(bit32.lshift(bit32.band(nPcp, 7), 13),
                           bit32.band(nVid, 0xFFF))
    return string.char(math.floor(nTci / 256) % 256, nTci % 256)
end

local function fUnpackVlanTag(sTag)
    if not sTag or #sTag < 2 then return 0, 0 end
    local nTci = sTag:byte(1) * 256 + sTag:byte(2)
    local nVid = bit32.band(nTci, 0xFFF)
    local nPcp = bit32.rshift(nTci, 13)
    return nVid, nPcp
end

-- =============================================
-- FRAME ENCAPSULATION
--
-- Untagged frame:  <TYPE:2><PAYLOAD>
-- VLAN frame:      "VL"<VLANTAG:2><TYPE:2><PAYLOAD>
-- =============================================

local function fEncapsulate(sFrameType, sPayload, nVlanId)
    if nVlanId and nVlanId > 0 then
        g_tStats.nVlanTagged = g_tStats.nVlanTagged + 1
        return FRAME_VLAN .. fPackVlanTag(nVlanId) .. sFrameType .. sPayload
    end
    g_tStats.nVlanUntagged = g_tStats.nVlanUntagged + 1
    return sFrameType .. sPayload
end

local function fDecapsulate(sRawFrame)
    if not sRawFrame or #sRawFrame < 2 then
        return nil, nil, nil, "frame too short"
    end

    local sMarker = sRawFrame:sub(1, 2)
    local nVlanId = 0

    if sMarker == FRAME_VLAN then
        -- VLAN-tagged frame
        if #sRawFrame < 6 then return nil, nil, nil, "vlan frame truncated" end
        local sTag = sRawFrame:sub(3, 4)
        nVlanId = fUnpackVlanTag(sTag)
        local sInnerType = sRawFrame:sub(5, 6)
        local sPayload   = sRawFrame:sub(7)
        g_tStats.nVlanTagged = g_tStats.nVlanTagged + 1
        return sInnerType, sPayload, nVlanId, nil
    else
        -- Untagged frame
        g_tStats.nVlanUntagged = g_tStats.nVlanUntagged + 1
        return sMarker, sRawFrame:sub(3), 0, nil
    end
end

-- =============================================
-- VLAN FILTERING
-- Returns true if frame should be accepted
-- =============================================

local function fVlanFilter(nFrameVid)
    if g_sVlanMode == "access" then
        -- Access port: accept untagged (vid=0) or matching native VLAN
        if nFrameVid == 0 or nFrameVid == g_nNativeVlan then return true end
        return false
    elseif g_sVlanMode == "trunk" then
        -- Trunk port: accept any allowed VLAN
        if nFrameVid == 0 then return true end  -- untagged always accepted
        return g_tTrunkVlans[nFrameVid] == true
    end
    return true  -- default: accept all
end

-- =============================================
-- TRANSMIT PATH
-- =============================================

local function fTransmitUnicast(sDstModem, sFrameType, sPayload, nVlanOverride)
    if not g_oModemProxy or not g_bUp then
        g_tStats.nTxDropped = g_tStats.nTxDropped + 1
        return false, "interface down"
    end

    local nVid = nVlanOverride or g_nNativeVlan
    local sFrame = fEncapsulate(sFrameType, sPayload, nVid)

    if #sFrame > g_nMTU then
        g_tStats.nTxErrors = g_tStats.nTxErrors + 1
        return false, "frame exceeds MTU"
    end

    local bOk = pcall(g_oModemProxy.send, sDstModem, PORT_IP_STACK, sFrame)
    if bOk then
        g_tStats.nTxPackets = g_tStats.nTxPackets + 1
        g_tStats.nTxBytes   = g_tStats.nTxBytes + #sFrame
        if sFrameType == FRAME_ARP then g_tStats.nArpTx = g_tStats.nArpTx + 1 end
        return true
    else
        g_tStats.nTxErrors = g_tStats.nTxErrors + 1
        return false, "modem send failed"
    end
end

local function fTransmitBroadcast(sFrameType, sPayload, nVlanOverride)
    if not g_oModemProxy or not g_bUp then
        g_tStats.nTxDropped = g_tStats.nTxDropped + 1
        return false, "interface down"
    end

    local nVid = nVlanOverride or g_nNativeVlan
    local sFrame = fEncapsulate(sFrameType, sPayload, nVid)

    if #sFrame > g_nMTU then
        g_tStats.nTxErrors = g_tStats.nTxErrors + 1
        return false, "frame exceeds MTU"
    end

    local bOk = pcall(g_oModemProxy.broadcast, PORT_IP_STACK, sFrame)
    if bOk then
        g_tStats.nTxPackets   = g_tStats.nTxPackets + 1
        g_tStats.nTxBytes     = g_tStats.nTxBytes + #sFrame
        g_tStats.nTxBroadcast = g_tStats.nTxBroadcast + 1
        if sFrameType == FRAME_ARP then g_tStats.nArpTx = g_tStats.nArpTx + 1 end
        return true
    else
        g_tStats.nTxErrors = g_tStats.nTxErrors + 1
        return false, "modem broadcast failed"
    end
end

-- =============================================
-- RECEIVE PATH (called from interrupt handler)
-- =============================================

local function fReceiveFrame(sRemoteModem, nPort, sRawFrame, nDistance)
    if not g_bUp then
        g_tStats.nRxDropped = g_tStats.nRxDropped + 1
        return
    end
    if nPort ~= PORT_IP_STACK then return end  -- wrong port

    g_tStats.nRxPackets = g_tStats.nRxPackets + 1
    g_tStats.nRxBytes   = g_tStats.nRxBytes + #sRawFrame

    -- Decapsulate
    local sType, sPayload, nVlanId, sErr = fDecapsulate(sRawFrame)
    if not sType then
        g_tStats.nRxErrors = g_tStats.nRxErrors + 1
        return
    end

    -- VLAN filtering
    if not fVlanFilter(nVlanId) then
        g_tStats.nRxDropped = g_tStats.nRxDropped + 1
        return
    end

    if sType == FRAME_ARP then
        g_tStats.nArpRx = g_tStats.nArpRx + 1
    end

    -- Queue for stack consumption
    if #g_tRxQueue < g_nRxQueueMax then
        g_tRxQueue[#g_tRxQueue + 1] = {
            sRemoteModem = sRemoteModem,
            sType        = sType,
            sPayload     = sPayload,
            nVlanId      = nVlanId,
            nDistance     = nDistance,
            nTimestamp    = os.clock(),
        }
    else
        g_tStats.nRxDropped = g_tStats.nRxDropped + 1
    end

    -- Feed to network stack if loaded
    pcall(function()
        local oStack = require("net/stack")
        oStack.receiveFrame(g_sIfaceName, sRemoteModem,
            sType .. sPayload)  -- stack expects TYPE+PAYLOAD
    end)
end

-- =============================================
-- IRP HANDLERS
-- =============================================

local function fCreate(pDev, pIrp)
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

local function fClose(pDev, pIrp)
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

local function fDevCtl(pDev, pIrp)
    local sMethod = pIrp.tParameters.sMethod
    local tArgs   = pIrp.tParameters.tArgs or {}

    if sMethod == "info" then
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, {
            sModemAddr = g_sModemAddr,
            sIfaceName = g_sIfaceName,
            bOnline    = g_oModemProxy ~= nil,
            bUp        = g_bUp,
            nMTU       = g_nMTU,
            sVlanMode  = g_sVlanMode,
            nNativeVlan = g_nNativeVlan,
            tStats     = g_tStats,
        })

    elseif sMethod == "send_frame" then
        local sDst   = tArgs[1]
        local sFrame = tArgs[2]
        local nVlan  = tArgs[3]
        if g_oModemProxy and sDst and sFrame then
            -- Determine frame type from first 2 bytes
            local sType = sFrame:sub(1, 2)
            local sPayload = sFrame:sub(3)
            local bOk = fTransmitUnicast(sDst, sType, sPayload, nVlan)
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, bOk)
        else
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_DEVICE_NOT_READY)
        end

    elseif sMethod == "broadcast_frame" then
        local sFrame = tArgs[1]
        local nVlan  = tArgs[2]
        if g_oModemProxy and sFrame then
            local sType = sFrame:sub(1, 2)
            local sPayload = sFrame:sub(3)
            local bOk = fTransmitBroadcast(sType, sPayload, nVlan)
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, bOk)
        else
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_DEVICE_NOT_READY)
        end

    elseif sMethod == "set_vlan" then
        local sMode = tArgs[1]  -- "access" or "trunk"
        local nVid  = tArgs[2]  -- native VLAN ID
        if sMode then g_sVlanMode = sMode end
        if nVid  then g_nNativeVlan = nVid end
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)

    elseif sMethod == "add_trunk_vlan" then
        local nVid = tArgs[1]
        if nVid and nVid > 0 and nVid < 4096 then
            g_tTrunkVlans[nVid] = true
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
        else
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER)
        end

    elseif sMethod == "remove_trunk_vlan" then
        g_tTrunkVlans[tArgs[1] or 0] = nil
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)

    elseif sMethod == "get_stats" then
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, g_tStats)

    elseif sMethod == "reset_stats" then
        for k in pairs(g_tStats) do g_tStats[k] = 0 end
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)

    elseif sMethod == "set_mtu" then
        local n = tonumber(tArgs[1])
        if n and n >= 64 and n <= 8192 then
            g_nMTU = n
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
        else
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER)
        end

    elseif sMethod == "set_up" then
        g_bUp = tArgs[1] ~= false
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)

    elseif sMethod == "poll_rx" then
        -- Dequeue one received frame (for polling mode)
        if #g_tRxQueue > 0 then
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS,
                table.remove(g_tRxQueue, 1))
        else
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_END_OF_FILE)
        end

    elseif sMethod == "get_hw_addr" then
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, g_sModemAddr)

    else
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_NOT_IMPLEMENTED)
    end
end

-- =============================================
-- DRIVER ENTRY
-- =============================================

function DriverEntry(pDriverObject)
    oKMD.DkPrint("AxisModemNIC v2.0: Initializing...")

    pDriverObject.tDispatch[tDKStructs.IRP_MJ_CREATE]         = fCreate
    pDriverObject.tDispatch[tDKStructs.IRP_MJ_CLOSE]          = fClose
    pDriverObject.tDispatch[tDKStructs.IRP_MJ_DEVICE_CONTROL] = fDevCtl

    local nSt, pDev = oKMD.DkCreateDevice(pDriverObject, "\\Device\\ModemNIC0")
    if nSt ~= tStatus.STATUS_SUCCESS then
        oKMD.DkPrint("AxisModemNIC: Device creation failed")
        return nSt
    end
    g_pDeviceObject = pDev
    oKMD.DkCreateSymbolicLink("/dev/nic0", "\\Device\\ModemNIC0")

    -- Find modem component
    local bOk, tList = syscall("raw_component_list", "modem")
    if bOk and tList then
        for sAddr in pairs(tList) do
            local _, oProxy = oKMD.DkGetHardwareProxy(sAddr)
            if oProxy then
                g_oModemProxy = oProxy
                g_sModemAddr  = sAddr
                pcall(oProxy.open, PORT_IP_STACK)
                pcall(oProxy.open, PORT_DNS)
                -- Set modem strength to max
                pcall(oProxy.setStrength, 400)
                oKMD.DkPrint("AxisModemNIC: Modem " .. sAddr:sub(1,8) ..
                    " bound, ports " .. PORT_IP_STACK .. "," .. PORT_DNS)
                break
            end
        end
    end

    if not g_oModemProxy then
        oKMD.DkPrint("AxisModemNIC: No modem found (offline)")
    end

    oKMD.DkRegisterInterrupt("modem_message")
    oKMD.DkPrint("AxisModemNIC v2.0: Ready at /dev/nic0" ..
        (g_oModemProxy and (" [" .. g_sModemAddr:sub(1,8) .. "]") or " [OFFLINE]"))
    return tStatus.STATUS_SUCCESS
end

function DriverUnload(pDriverObject)
    if g_oModemProxy then
        pcall(g_oModemProxy.close, PORT_IP_STACK)
        pcall(g_oModemProxy.close, PORT_DNS)
    end
    oKMD.DkDeleteSymbolicLink("/dev/nic0")
    oKMD.DkDeleteDevice(g_pDeviceObject)
    return tStatus.STATUS_SUCCESS
end

-- =============================================
-- MAIN LOOP
-- =============================================

while true do
    local bOk, nSender, sSig, p1, p2, p3, p4, p5, p6 = syscall("signal_pull")
    if bOk then
        if sSig == "driver_init" then
            local pDO = p1
            pDO.fDriverUnload = DriverUnload
            local nSt = DriverEntry(pDO)
            syscall("signal_send", nSender, "driver_init_complete", nSt, pDO)

        elseif sSig == "irp_dispatch" then
            local pIrp = p1
            local fHandler = p2
            if fHandler then fHandler(g_pDeviceObject, pIrp) end

        elseif sSig == "hardware_interrupt" and p1 == "modem_message" then
            -- p2=localAddr, p3=remoteAddr, p4=port, p5=distance, p6=data
            if p4 == PORT_IP_STACK and p6 then
                fReceiveFrame(p3, p4, p6, p5)
            end
        end
    end
end