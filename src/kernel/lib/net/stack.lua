--
-- /lib/net/stack.lua
-- AxisOS Network Stack — Ties IP, lnqiobuf, and nftables together
--
-- Packet flow:
--   RX: modem_message → NIC driver → lnqiobuf ring → IP parse →
--       nftables(PREROUTING) → routing decision →
--       nftables(INPUT) → deliver to socket
--                 or
--       nftables(FORWARD) → nftables(POSTROUTING) → TX
--
--   TX: socket send → nftables(OUTPUT) → routing →
--       nftables(POSTROUTING) → ARP resolve → modem.send
--

local IP    = require("net/ipproto")
local LNQIO = require("net/lnqiobuf")
local NFT   = require("net/nftables")

local STACK = {}

-- =============================================
-- STATE
-- =============================================

local g_tInterfaces  = {}   -- [sName] = {sIP, sMask, sGateway, sModemAddr, bUp}
local g_oRouteTable  = IP.RoutingTable.new()
local g_oArpTable    = IP.ARPTable.new()
local g_oFragTable   = IP.FragTable.new()
local g_tRxRings     = {}   -- [sIfaceName] → lnqiobuf ring
local g_tSockets     = {}   -- [nSockId] → socket state
local g_nNextSock    = 1
local g_bForwarding  = false  -- IP forwarding (router mode)
local g_fLog         = function() end

-- =============================================
-- INITIALIZATION
-- =============================================

function STACK.init(tConfig)
    tConfig = tConfig or {}
    g_fLog = tConfig.fLog or g_fLog
    g_bForwarding = tConfig.bForwarding or false

    -- Set up default nftables
    NFT.setupDefaults()

    g_fLog("[STACK] Network stack initialized")
    g_fLog("[STACK]   IP forwarding: " .. tostring(g_bForwarding))
    return true
end

-- =============================================
-- INTERFACE MANAGEMENT
-- =============================================

function STACK.addInterface(sName, tCfg)
    local sIP   = IP.parseAddr(tCfg.sIP or "0.0.0.0")
    local sMask = IP.parseAddr(tCfg.sMask or "255.255.255.0")

    g_tInterfaces[sName] = {
        sName      = sName,
        sIP        = sIP,
        sMask      = sMask,
        sGateway   = tCfg.sGateway and IP.parseAddr(tCfg.sGateway),
        sModemAddr = tCfg.sModemAddr,
        bUp        = true,
        nMTU       = tCfg.nMTU or 8000,
        tStats     = {nRxPkts=0, nTxPkts=0, nRxBytes=0, nTxBytes=0, nDrops=0},
    }

    -- Add connected route
    local sNet = IP.networkAddr(sIP, sMask)
    local nPrefix = 0
    local nMask = IP.addrToU32(sMask)
    while nMask > 0 and bit32.band(nMask, 0x80000000) ~= 0 do
        nPrefix = nPrefix + 1
        nMask = bit32.lshift(nMask, 1)
    end

    g_oRouteTable:add(
        IP.formatAddr(sNet) .. "/" .. nPrefix,
        nil,  -- direct (no gateway)
        sName)

    -- Add default route if gateway specified
    if tCfg.sGateway then
        g_oRouteTable:add("0.0.0.0/0", tCfg.sGateway, sName, 200)
    end

    -- Create lnqiobuf RX ring for this interface
    g_tRxRings[sName] = LNQIO.create("netif_" .. sName, 128, 32768)

    g_fLog(string.format("[STACK] Interface %s: %s/%d via %s",
        sName, IP.formatAddr(sIP), nPrefix,
        tCfg.sModemAddr and tCfg.sModemAddr:sub(1,8) or "?"))

    return true
end

function STACK.getInterface(sName)
    return g_tInterfaces[sName]
end

function STACK.getLocalIP(sIfaceName)
    local tIf = g_tInterfaces[sIfaceName]
    return tIf and tIf.sIP
end

--- Check if an IP address belongs to any local interface
function STACK.isLocalAddr(sAddr)
    for _, tIf in pairs(g_tInterfaces) do
        if tIf.sIP == sAddr then return true, tIf.sName end
    end
    if sAddr == IP.ADDR_LOOPBACK then return true, "lo" end
    return false
end

-- =============================================
-- PACKET RECEPTION (from NIC driver)
-- =============================================

--- Called by NIC driver when a packet arrives from the modem.
-- The raw modem payload is: FRAME_TYPE(2) + packet_data
function STACK.receiveFrame(sIfaceName, sRemoteModem, sFrameData)
    local tIf = g_tInterfaces[sIfaceName]
    if not tIf or not tIf.bUp then return end

    tIf.tStats.nRxPkts = tIf.tStats.nRxPkts + 1
    tIf.tStats.nRxBytes = tIf.tStats.nRxBytes + #sFrameData

    -- Check frame type
    local sType = sFrameData:sub(1, 2)
    local sPayload = sFrameData:sub(3)

    if sType == IP.FRAME_ARP then
        -- Handle ARP
        STACK._handleARP(sIfaceName, sRemoteModem, sPayload)
        return
    end

    if sType ~= IP.FRAME_IP then
        return  -- unknown frame type, drop
    end

    -- Parse IP header
    local tIP = IP.parsePacket(sPayload)
    if not tIP then
        tIf.tStats.nDrops = tIf.tStats.nDrops + 1
        return
    end

    -- Handle fragments
    if tIP.bMF or tIP.nFragOff > 0 then
        local sReassembled = g_oFragTable:add(tIP)
        if not sReassembled then return end  -- still waiting for fragments
        -- Re-parse the complete packet
        local sComplete = IP.packIPHeader({
            sSrc = tIP.sSrc, sDst = tIP.sDst,
            nProto = tIP.nProto, nTTL = tIP.nTTL,
            nId = tIP.nId,
        }, #sReassembled) .. sReassembled
        tIP = IP.parsePacket(sComplete)
        if not tIP then return end
    end

    -- Build packet info for nftables
    local tPkt = {
        nProto    = tIP.nProto,
        sSrcIP    = IP.formatAddr(tIP.sSrc),
        sDstIP    = IP.formatAddr(tIP.sDst),
        nSrcPort  = tIP.tTransport and tIP.tTransport.nSrcPort or 0,
        nDstPort  = tIP.tTransport and tIP.tTransport.nDstPort or 0,
        nTcpFlags = tIP.tTransport and tIP.tTransport.nFlags or 0,
        nLength   = tIP.nTotalLen,
        nTTL      = tIP.nTTL,
        sIface    = sIfaceName,
        nMark     = 0,
        sRaw      = sPayload,
        tIP       = tIP,
        fLog      = g_fLog,
    }

    -- ════════ PREROUTING ════════
    local nVerdict = NFT.hook(NFT.HOOK_PREROUTING, tPkt)
    if nVerdict ~= NFT.NF_ACCEPT then
        tIf.tStats.nDrops = tIf.tStats.nDrops + 1
        return
    end

    -- Apply DNAT if set
    if tPkt.tNAT and tPkt.tNAT.sType == "dnat" then
        tPkt.sDstIP = tPkt.tNAT.sNewDst
        if tPkt.tNAT.nNewPort then
            tPkt.nDstPort = tPkt.tNAT.nNewPort
        end
    end

    -- Routing decision: local delivery or forwarding?
    local bLocal = STACK.isLocalAddr(tIP.sDst)

    if bLocal then
        -- ════════ INPUT ════════
        nVerdict = NFT.hook(NFT.HOOK_INPUT, tPkt)
        if nVerdict ~= NFT.NF_ACCEPT then return end

        -- Store in lnqiobuf for application consumption
        local tRing = g_tRxRings[sIfaceName]
        if tRing then
            tRing:produce(sPayload, {
                nProto   = tIP.nProto,
                nSrcIP   = IP.addrToU32(tIP.sSrc),
                nDstIP   = IP.addrToU32(tIP.sDst),
                nSrcPort = tPkt.nSrcPort,
                nDstPort = tPkt.nDstPort,
                nFlags   = 0,
            })
        end

        -- Deliver to matching socket
        STACK._deliverToSocket(tPkt)

    elseif g_bForwarding then
        -- ════════ FORWARD ════════
        -- Decrement TTL
        if tIP.nTTL <= 1 then
            -- Send ICMP Time Exceeded
            return
        end

        nVerdict = NFT.hook(NFT.HOOK_FORWARD, tPkt)
        if nVerdict ~= NFT.NF_ACCEPT then return end

        -- Forward: rebuild packet with decremented TTL and send
        STACK._forwardPacket(tPkt)
    end
    -- Not local and not forwarding → drop silently
end

-- =============================================
-- PACKET TRANSMISSION
-- =============================================

function STACK._forwardPacket(tPkt)
    local tIP = tPkt.tIP

    -- Rebuild with TTL-1
    local sNewPayload = tIP.sPayload
    local sNewPacket = IP.buildPacket(
        tIP.sSrc, tIP.sDst, tIP.nProto, sNewPayload, {
            nTTL  = tIP.nTTL - 1,
            nId   = tIP.nId,
            nDSCP = tIP.nDSCP,
        })

    -- Update pkt info for POSTROUTING
    tPkt.sRaw = sNewPacket

    -- ════════ POSTROUTING ════════
    local nVerdict = NFT.hook(NFT.HOOK_POSTROUTING, tPkt)
    if nVerdict ~= NFT.NF_ACCEPT then return end

    -- Apply SNAT/masquerade if set
    if tPkt.tNAT then
        -- Would need to rebuild packet with new source
        -- (Left as TODO for full NAT rewrite)
    end

    -- Route and send
    STACK._sendPacket(sNewPacket, tIP.sDst)
end

--- Send a raw IP packet via the appropriate interface.
function STACK._sendPacket(sPacket, sDstIP)
    -- Lookup route
    local tRoute = g_oRouteTable:lookup(IP.formatAddr(sDstIP))
    if not tRoute then
        g_fLog("[STACK] No route to " .. IP.formatAddr(sDstIP))
        return false
    end

    local tIf = g_tInterfaces[tRoute.sInterface]
    if not tIf or not tIf.bUp then return false end

    -- Determine next-hop
    local sNextHop = tRoute.sGateway or sDstIP

    -- ARP resolve
    local sModemDst = g_oArpTable:get(sNextHop)
    if not sModemDst then
        -- Send ARP request
        STACK._sendARP(tRoute.sInterface, IP.ARP_REQUEST,
            tIf.sModemAddr, tIf.sIP, "", sNextHop)
        -- Queue packet for later (simplified: just drop for now)
        g_fLog("[STACK] ARP miss for " .. IP.formatAddr(sNextHop))
        return false
    end

    -- Fragment if needed
    if #sPacket > tIf.nMTU then
        local tFrags = IP.fragment(sPacket, tIf.nMTU)
        if not tFrags then return false end
        for _, sFrag in ipairs(tFrags) do
            STACK._transmitFrame(tIf, sModemDst, IP.FRAME_IP .. sFrag)
        end
        return true
    end

    -- Transmit
    STACK._transmitFrame(tIf, sModemDst, IP.FRAME_IP .. sPacket)
    return true
end

--- Low-level frame transmission via modem
function STACK._transmitFrame(tIf, sModemDst, sFrame)
    if not tIf.sModemAddr then return false end

    -- Use modem component to send
    local bOk = pcall(function()
        local oModem
        for addr in raw_component.list("modem") do
            if addr == tIf.sModemAddr then
                oModem = raw_component.proxy(addr)
                break
            end
        end
        if oModem then
            oModem.send(sModemDst, 1, sFrame)  -- port 1 = IP stack
        end
    end)

    if bOk then
        tIf.tStats.nTxPkts = tIf.tStats.nTxPkts + 1
        tIf.tStats.nTxBytes = tIf.tStats.nTxBytes + #sFrame
    end
    return bOk
end

-- =============================================
-- ARP HANDLING
-- =============================================

function STACK._handleARP(sIfaceName, sRemoteModem, sData)
    local tARP = IP.unpackARP(sData)
    if not tARP then return end

    local tIf = g_tInterfaces[sIfaceName]
    if not tIf then return end

    -- Learn sender's mapping
    g_oArpTable:set(tARP.sSenderIP, tARP.sSenderHW)

    if tARP.nOpcode == IP.ARP_REQUEST then
        -- Is it asking for our IP?
        if tARP.sTargetIP == tIf.sIP then
            -- Send ARP reply
            STACK._sendARP(sIfaceName, IP.ARP_REPLY,
                tIf.sModemAddr, tIf.sIP,
                tARP.sSenderHW, tARP.sSenderIP)
        end
    end
end

function STACK._sendARP(sIfaceName, nOpcode, sSrcHW, sSrcIP, sDstHW, sDstIP)
    local tIf = g_tInterfaces[sIfaceName]
    if not tIf then return end

    local sArpPacket = IP.packARP(nOpcode, sSrcHW, sSrcIP, sDstHW, sDstIP)
    local sFrame = IP.FRAME_ARP .. sArpPacket

    if nOpcode == IP.ARP_REQUEST and (not sDstHW or sDstHW == "") then
        -- Broadcast ARP request
        pcall(function()
            local oModem = raw_component.proxy(tIf.sModemAddr)
            if oModem then oModem.broadcast(1, sFrame) end
        end)
    else
        STACK._transmitFrame(tIf, sDstHW, sFrame)
    end
end

-- =============================================
-- SOCKET DELIVERY
-- =============================================

function STACK._deliverToSocket(tPkt)
    for _, tSock in pairs(g_tSockets) do
        if tSock.nProto == tPkt.nProto
           and (tSock.nLocalPort == 0 or tSock.nLocalPort == tPkt.nDstPort)
           and (tSock.sLocalIP == nil or tSock.sLocalIP == tPkt.sDstIP
                or tSock.sLocalIP == "0.0.0.0") then
            -- Deliver via message queue
            if tSock.hMQueue then
                pcall(syscall, "ke_mq_send", tSock.hMQueue,
                    tPkt.sRaw, 0)
            end
            if tSock.nProto == IP.PROTO_TCP then
                break  -- TCP: only one socket per port
            end
        end
    end
end

-- =============================================
-- APPLICATION SOCKET API
-- =============================================

function STACK.socket(nProto)
    local nId = g_nNextSock; g_nNextSock = g_nNextSock + 1
    g_tSockets[nId] = {
        nId        = nId,
        nProto     = nProto,
        sLocalIP   = nil,
        nLocalPort = 0,
        sRemoteIP  = nil,
        nRemotePort = 0,
        hMQueue    = nil,
        sState     = "unbound",
    }
    return nId
end

function STACK.bind(nSockId, sAddr, nPort)
    local tSock = g_tSockets[nSockId]
    if not tSock then return false end
    tSock.sLocalIP = sAddr
    tSock.nLocalPort = nPort
    tSock.hMQueue = syscall("ke_create_mqueue",
        "sock_" .. nSockId, 32, 8192)
    tSock.sState = "bound"
    return true
end

function STACK.sendto(nSockId, sData, sAddr, nPort)
    local tSock = g_tSockets[nSockId]
    if not tSock then return false end

    local sSrcIP = tSock.sLocalIP
    if not sSrcIP or sSrcIP == "0.0.0.0" then
        -- Pick interface based on routing
        local tRoute = g_oRouteTable:lookup(sAddr)
        if tRoute then
            local tIf = g_tInterfaces[tRoute.sInterface]
            if tIf then sSrcIP = IP.formatAddr(tIf.sIP) end
        end
    end
    if not sSrcIP then return false, "no source IP" end

    local sSrc = IP.parseAddr(sSrcIP)
    local sDst = IP.parseAddr(sAddr)
    if not sSrc or not sDst then return false end

    local sPacket
    if tSock.nProto == IP.PROTO_UDP then
        sPacket = IP.buildUDPPacket(sSrc, sDst,
            tSock.nLocalPort, nPort, sData)
    elseif tSock.nProto == IP.PROTO_ICMP then
        sPacket = IP.buildPing(sSrc, sDst,
            tSock.nLocalPort, 1, sData)
    else
        return false, "unsupported protocol"
    end

    -- OUTPUT hook
    local tPkt = {
        nProto   = tSock.nProto,
        sSrcIP   = sSrcIP,
        sDstIP   = sAddr,
        nSrcPort = tSock.nLocalPort,
        nDstPort = nPort,
        nLength  = #sPacket,
        sIface   = "lo",
        nMark    = 0,
        sRaw     = sPacket,
        fLog     = g_fLog,
    }
    local nV = NFT.hook(NFT.HOOK_OUTPUT, tPkt)
    if nV ~= NFT.NF_ACCEPT then return false, "filtered" end

    -- POSTROUTING hook
    nV = NFT.hook(NFT.HOOK_POSTROUTING, tPkt)
    if nV ~= NFT.NF_ACCEPT then return false, "filtered" end

    return STACK._sendPacket(sPacket, sDst)
end

function STACK.recvfrom(nSockId, nTimeoutMs)
    local tSock = g_tSockets[nSockId]
    if not tSock or not tSock.hMQueue then return nil end
    return syscall("ke_mq_receive", tSock.hMQueue, nTimeoutMs)
end

function STACK.close(nSockId)
    g_tSockets[nSockId] = nil
    return true
end

-- =============================================
-- DIAGNOSTICS
-- =============================================

function STACK.getRoutes()      return g_oRouteTable:dump() end
function STACK.getArpTable()    return g_oArpTable:dump() end
function STACK.getConntrack()   return NFT.getConntrack() end
function STACK.getInterfaces()
    local t = {}
    for sName, tIf in pairs(g_tInterfaces) do
        t[#t + 1] = {
            name  = sName,
            ip    = IP.formatAddr(tIf.sIP),
            mask  = IP.formatAddr(tIf.sMask),
            gw    = tIf.sGateway and IP.formatAddr(tIf.sGateway) or nil,
            modem = tIf.sModemAddr and tIf.sModemAddr:sub(1,8) or nil,
            up    = tIf.bUp,
            stats = tIf.tStats,
        }
    end
    return t
end

function STACK.setForwarding(b)
    g_bForwarding = b
    g_fLog("[STACK] IP forwarding " .. (b and "ENABLED" or "DISABLED"))
end

function STACK.tick()
    NFT.tick()
    g_oArpTable:gc()
    g_oFragTable:gc()
end

return STACK