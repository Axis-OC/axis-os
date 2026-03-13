--
-- /lib/net/ipproto.lua
-- AxisOS IP Protocol Stack — Binary Packet Engine
--
-- Implements real IP/TCP/UDP/ICMP/ARP packet structures with
-- checksums, routing, fragmentation, and address resolution.
-- Packets are transmitted over OC modem components (Layer 2).
--
-- This is NOT an application-level HTTP wrapper.  This is a
-- packet-level network stack that simulates real internet
-- protocols over OpenComputers hardware.
--

local IP = {}

-- =============================================
-- CONSTANTS
-- =============================================

IP.VERSION            = 4
IP.DEFAULT_TTL        = 64
IP.MAX_PACKET_SIZE    = 8192   -- OC modem max payload
IP.MIN_IP_HEADER      = 20
IP.MIN_TCP_HEADER     = 20
IP.UDP_HEADER_SIZE    = 8
IP.ICMP_HEADER_SIZE   = 8
IP.ARP_PACKET_SIZE    = 28

-- Protocol numbers (IANA)
IP.PROTO_ICMP = 1
IP.PROTO_TCP  = 6
IP.PROTO_UDP  = 17

-- TCP flags (byte 13 of TCP header)
IP.TCP_FIN = 0x01
IP.TCP_SYN = 0x02
IP.TCP_RST = 0x04
IP.TCP_PSH = 0x08
IP.TCP_ACK = 0x10
IP.TCP_URG = 0x20

-- ICMP types   
IP.ICMP_ECHO_REPLY   = 0
IP.ICMP_DEST_UNREACH = 3
IP.ICMP_ECHO_REQUEST = 8
IP.ICMP_TIME_EXCEEDED = 11

-- ARP opcodes
IP.ARP_REQUEST = 1
IP.ARP_REPLY   = 2

-- Special addresses
IP.ADDR_ANY       = "\0\0\0\0"
IP.ADDR_BROADCAST = "\255\255\255\255"
IP.ADDR_LOOPBACK  = "\127\0\0\1"

-- Ethertype-like frame markers (first 2 bytes of modem payload)
IP.FRAME_IP  = "IP"
IP.FRAME_ARP = "AR"

-- =============================================
-- BINARY HELPERS (big-endian, like real networks)
-- =============================================

local band  = bit32.band
local bor   = bit32.bor
local bxor  = bit32.bxor
local rsh   = bit32.rshift
local lsh   = bit32.lshift

local function u8(n)  return string.char(band(n, 0xFF)) end
local function u16(n) return string.char(band(rsh(n, 8), 0xFF), band(n, 0xFF)) end
local function u32(n)
    return string.char(
        band(rsh(n, 24), 0xFF), band(rsh(n, 16), 0xFF),
        band(rsh(n, 8), 0xFF), band(n, 0xFF))
end

local function r8(s, o)  o = o or 1; return s:byte(o) end
local function r16(s, o) o = o or 1; return s:byte(o) * 256 + s:byte(o + 1) end
local function r32(s, o) o = o or 1
    return s:byte(o) * 16777216 + s:byte(o+1) * 65536
         + s:byte(o+2) * 256 + s:byte(o+3)
end

local function pad(s, n)
    if #s >= n then return s:sub(1, n) end
    return s .. string.rep("\0", n - #s)
end

-- =============================================
-- IP ADDRESS OPERATIONS
-- =============================================

--- Parse "10.0.0.1" → 4-byte binary string
function IP.parseAddr(s)
    if type(s) ~= "string" then return nil end
    if #s == 4 then return s end  -- already binary
    local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
    return string.char(a, b, c, d)
end

--- Binary 4-byte → "10.0.0.1"
function IP.formatAddr(bin)
    if not bin or #bin < 4 then return "0.0.0.0" end
    return string.format("%d.%d.%d.%d",
        bin:byte(1), bin:byte(2), bin:byte(3), bin:byte(4))
end

--- IP address as 32-bit number
function IP.addrToU32(bin)
    if not bin or #bin < 4 then return 0 end
    return r32(bin, 1)
end

function IP.u32ToAddr(n)
    return u32(n)
end

--- Parse CIDR: "10.0.0.0/24" → addr, mask, prefix_len
function IP.parseCIDR(s)
    local sAddr, sPfx = s:match("^([^/]+)/(%d+)$")
    if not sAddr then return nil end
    local nPfx = tonumber(sPfx)
    if nPfx < 0 or nPfx > 32 then return nil end
    local nMask = 0
    if nPfx > 0 then
        nMask = lsh(0xFFFFFFFF, 32 - nPfx)
        -- Ensure unsigned 32-bit
        nMask = band(nMask, 0xFFFFFFFF)
    end
    return IP.parseAddr(sAddr), IP.u32ToAddr(nMask), nPfx
end

--- Network address: addr AND mask
function IP.networkAddr(sAddr, sMask)
    local nA = IP.addrToU32(sAddr)
    local nM = IP.addrToU32(sMask)
    return IP.u32ToAddr(band(nA, nM))
end

--- Broadcast address: addr OR (NOT mask)
function IP.broadcastAddr(sAddr, sMask)
    local nA = IP.addrToU32(sAddr)
    local nM = IP.addrToU32(sMask)
    local nInv = band(bit32.bnot(nM), 0xFFFFFFFF)
    return IP.u32ToAddr(bor(nA, nInv))
end

--- Check if addr is in subnet
function IP.isInSubnet(sAddr, sNetwork, sMask)
    local nA = IP.addrToU32(sAddr)
    local nN = IP.addrToU32(sNetwork)
    local nM = IP.addrToU32(sMask)
    return band(nA, nM) == band(nN, nM)
end

--- Check if address is broadcast for given subnet
function IP.isBroadcast(sAddr, sNetwork, sMask)
    local sBcast = IP.broadcastAddr(sNetwork, sMask)
    return sAddr == sBcast or sAddr == IP.ADDR_BROADCAST
end

-- =============================================
-- INTERNET CHECKSUM (RFC 1071)
-- One's complement sum of 16-bit words
-- =============================================

function IP.checksum(sData)
    local nSum = 0
    local nLen = #sData

    -- Sum 16-bit words
    local i = 1
    while i + 1 <= nLen do
        nSum = nSum + sData:byte(i) * 256 + sData:byte(i + 1)
        i = i + 2
    end
    -- Odd byte
    if i <= nLen then
        nSum = nSum + sData:byte(i) * 256
    end

    -- Fold 32-bit carries into 16 bits
    while nSum > 0xFFFF do
        nSum = band(nSum, 0xFFFF) + rsh(nSum, 16)
    end

    -- One's complement
    return band(bit32.bnot(nSum), 0xFFFF)
end

--- Verify checksum (result should be 0 for valid packet)
function IP.verifyChecksum(sData)
    return IP.checksum(sData) == 0
end

-- =============================================
-- TCP/UDP PSEUDO-HEADER CHECKSUM
-- Used by TCP and UDP for end-to-end integrity
-- =============================================

function IP.pseudoHeaderChecksum(sSrcIP, sDstIP, nProto, nLength, sSegment)
    -- Pseudo-header: srcIP(4) + dstIP(4) + zero(1) + proto(1) + length(2)
    local sPseudo = sSrcIP .. sDstIP
                 .. "\0" .. u8(nProto) .. u16(nLength)
    return IP.checksum(sPseudo .. sSegment)
end

-- =============================================
-- IP HEADER PACK / UNPACK
-- =============================================

--- Pack an IP header (20 bytes, no options)
-- tH fields: {sSrc, sDst, nProto, nTTL, nId, nFlags, nFragOff, sDSCP}
function IP.packIPHeader(tH, nPayloadLen)
    local nIHL    = 5  -- 20 bytes, no options
    local nVerIHL = bor(lsh(IP.VERSION, 4), nIHL)
    local nTOS    = tH.nDSCP or 0
    local nTotal  = IP.MIN_IP_HEADER + (nPayloadLen or 0)
    local nId     = tH.nId or 0
    local nFlagOff = bor(lsh(tH.nFlags or 0, 13), tH.nFragOff or 0)
    local nTTL    = tH.nTTL or IP.DEFAULT_TTL
    local nProto  = tH.nProto or 0
    local sSrc    = tH.sSrc or IP.ADDR_ANY
    local sDst    = tH.sDst or IP.ADDR_ANY

    -- Build header with checksum = 0, then compute
    local sHdr = u8(nVerIHL) .. u8(nTOS) .. u16(nTotal)
              .. u16(nId) .. u16(nFlagOff)
              .. u8(nTTL) .. u8(nProto) .. "\0\0"  -- checksum placeholder
              .. sSrc .. sDst

    -- Compute and insert checksum at bytes 11-12
    local nCk = IP.checksum(sHdr)
    sHdr = sHdr:sub(1, 10) .. u16(nCk) .. sHdr:sub(13)

    return sHdr
end

--- Unpack an IP header → table
function IP.unpackIPHeader(sPacket)
    if not sPacket or #sPacket < IP.MIN_IP_HEADER then
        return nil, "packet too short"
    end

    local nVerIHL = r8(sPacket, 1)
    local nVer    = rsh(nVerIHL, 4)
    local nIHL    = band(nVerIHL, 0x0F)

    if nVer ~= 4 then return nil, "not IPv4" end
    if nIHL < 5 then return nil, "IHL < 5" end

    local nHdrLen = nIHL * 4
    if #sPacket < nHdrLen then return nil, "header truncated" end

    -- Verify header checksum
    if not IP.verifyChecksum(sPacket:sub(1, nHdrLen)) then
        return nil, "header checksum invalid"
    end

    local nFlagOff = r16(sPacket, 7)

    return {
        nVersion  = nVer,
        nIHL      = nIHL,
        nHdrLen   = nHdrLen,
        nDSCP     = rsh(r8(sPacket, 2), 2),
        nECN      = band(r8(sPacket, 2), 0x03),
        nTotalLen = r16(sPacket, 3),
        nId       = r16(sPacket, 5),
        nFlags    = rsh(nFlagOff, 13),
        nFragOff  = band(nFlagOff, 0x1FFF),
        bDF       = band(rsh(nFlagOff, 13), 0x02) ~= 0,  -- Don't Fragment
        bMF       = band(rsh(nFlagOff, 13), 0x01) ~= 0,  -- More Fragments
        nTTL      = r8(sPacket, 9),
        nProto    = r8(sPacket, 10),
        nChecksum = r16(sPacket, 11),
        sSrc      = sPacket:sub(13, 16),
        sDst      = sPacket:sub(17, 20),
        sPayload  = sPacket:sub(nHdrLen + 1),
        sRaw      = sPacket,
    }
end

-- =============================================
-- TCP HEADER PACK / UNPACK
-- =============================================

function IP.packTCPHeader(tH, sSrcIP, sDstIP, sPayload)
    sPayload = sPayload or ""
    local nDataOff = 5  -- 20 bytes, no options
    local nOffsetFlags = bor(lsh(nDataOff, 4), 0)  -- reserved bits = 0

    local sHdr = u16(tH.nSrcPort or 0) .. u16(tH.nDstPort or 0)
              .. u32(tH.nSeq or 0)
              .. u32(tH.nAck or 0)
              .. u8(lsh(nDataOff, 4))  -- data offset + reserved
              .. u8(tH.nFlags or 0)    -- TCP flags
              .. u16(tH.nWindow or 65535)
              .. "\0\0"                -- checksum placeholder
              .. u16(tH.nUrgent or 0)

    -- Compute pseudo-header checksum over header + payload
    local nCk = IP.pseudoHeaderChecksum(
        sSrcIP, sDstIP, IP.PROTO_TCP,
        #sHdr + #sPayload, sHdr .. sPayload)

    -- Insert checksum at bytes 17-18
    sHdr = sHdr:sub(1, 16) .. u16(nCk) .. sHdr:sub(19)

    return sHdr .. sPayload
end

function IP.unpackTCPHeader(sSegment, sSrcIP, sDstIP)
    if not sSegment or #sSegment < IP.MIN_TCP_HEADER then
        return nil, "TCP segment too short"
    end

    local nDataOff = rsh(r8(sSegment, 13), 4)
    local nHdrLen  = nDataOff * 4
    if nHdrLen < 20 then return nil, "TCP header too short" end

    -- Verify checksum
    local nCk = IP.pseudoHeaderChecksum(
        sSrcIP, sDstIP, IP.PROTO_TCP, #sSegment, sSegment)
    -- Note: result should be 0 for valid; checksum covers the stored checksum

    local nFlags = r8(sSegment, 14)

    return {
        nSrcPort  = r16(sSegment, 1),
        nDstPort  = r16(sSegment, 3),
        nSeq      = r32(sSegment, 5),
        nAck      = r32(sSegment, 9),
        nDataOff  = nDataOff,
        nHdrLen   = nHdrLen,
        nFlags    = nFlags,
        bFIN      = band(nFlags, IP.TCP_FIN) ~= 0,
        bSYN      = band(nFlags, IP.TCP_SYN) ~= 0,
        bRST      = band(nFlags, IP.TCP_RST) ~= 0,
        bPSH      = band(nFlags, IP.TCP_PSH) ~= 0,
        bACK      = band(nFlags, IP.TCP_ACK) ~= 0,
        bURG      = band(nFlags, IP.TCP_URG) ~= 0,
        nWindow   = r16(sSegment, 15),
        nChecksum = r16(sSegment, 17),
        nUrgent   = r16(sSegment, 19),
        sPayload  = #sSegment > nHdrLen and sSegment:sub(nHdrLen + 1) or "",
        sRaw      = sSegment,
        bChecksumOk = (nCk == 0),
    }
end

-- =============================================
-- UDP HEADER PACK / UNPACK
-- =============================================

function IP.packUDPHeader(tH, sSrcIP, sDstIP, sPayload)
    sPayload = sPayload or ""
    local nLen = IP.UDP_HEADER_SIZE + #sPayload

    local sHdr = u16(tH.nSrcPort or 0) .. u16(tH.nDstPort or 0)
              .. u16(nLen) .. "\0\0"  -- checksum placeholder

    local nCk = IP.pseudoHeaderChecksum(
        sSrcIP, sDstIP, IP.PROTO_UDP,
        nLen, sHdr .. sPayload)
    if nCk == 0 then nCk = 0xFFFF end  -- UDP: 0 means no checksum

    sHdr = sHdr:sub(1, 6) .. u16(nCk) .. sHdr:sub(9)

    return sHdr .. sPayload
end

function IP.unpackUDPHeader(sSegment, sSrcIP, sDstIP)
    if not sSegment or #sSegment < IP.UDP_HEADER_SIZE then
        return nil, "UDP datagram too short"
    end

    local nLen = r16(sSegment, 5)

    return {
        nSrcPort  = r16(sSegment, 1),
        nDstPort  = r16(sSegment, 3),
        nLength   = nLen,
        nChecksum = r16(sSegment, 7),
        sPayload  = #sSegment > 8 and sSegment:sub(9) or "",
        sRaw      = sSegment,
    }
end

-- =============================================
-- ICMP PACK / UNPACK
-- =============================================

function IP.packICMP(nType, nCode, nId, nSeq, sPayload)
    sPayload = sPayload or ""
    local sHdr = u8(nType) .. u8(nCode) .. "\0\0"  -- checksum placeholder
              .. u16(nId or 0) .. u16(nSeq or 0)
    local nCk = IP.checksum(sHdr .. sPayload)
    sHdr = sHdr:sub(1, 2) .. u16(nCk) .. sHdr:sub(5)
    return sHdr .. sPayload
end

function IP.unpackICMP(sData)
    if not sData or #sData < IP.ICMP_HEADER_SIZE then
        return nil, "ICMP too short"
    end
    return {
        nType     = r8(sData, 1),
        nCode     = r8(sData, 2),
        nChecksum = r16(sData, 3),
        nId       = r16(sData, 5),
        nSeq      = r16(sData, 7),
        sPayload  = #sData > 8 and sData:sub(9) or "",
        bChecksumOk = IP.verifyChecksum(sData),
    }
end

-- =============================================
-- ARP PACK / UNPACK
-- Hardware type = 0xFFFF (OC modem, not Ethernet)
-- Protocol type = 0x0800 (IPv4)
-- HW addr len = 36 (UUID length)
-- Proto addr len = 4 (IPv4)
-- =============================================

-- ARP over OC modem: HW addresses are UUID strings (36 chars)
-- We use a simplified ARP that fits in a modem message

function IP.packARP(nOpcode, sSenderHW, sSenderIP, sTargetHW, sTargetIP)
    return u16(0xFFFF)        -- hardware type (OC modem)
        .. u16(0x0800)        -- protocol type (IPv4)
        .. u8(36)             -- HW addr length (UUID)
        .. u8(4)              -- proto addr length
        .. u16(nOpcode)       -- opcode
        .. pad(sSenderHW or "", 36)
        .. (sSenderIP or IP.ADDR_ANY)
        .. pad(sTargetHW or "", 36)
        .. (sTargetIP or IP.ADDR_ANY)
end

function IP.unpackARP(sData)
    if not sData or #sData < 88 then  -- 8 + 36 + 4 + 36 + 4
        return nil, "ARP too short"
    end
    return {
        nHWType    = r16(sData, 1),
        nProtoType = r16(sData, 3),
        nHWLen     = r8(sData, 5),
        nProtoLen  = r8(sData, 6),
        nOpcode    = r16(sData, 7),
        sSenderHW  = sData:sub(9, 44):gsub("\0+$", ""),
        sSenderIP  = sData:sub(45, 48),
        sTargetHW  = sData:sub(49, 84):gsub("\0+$", ""),
        sTargetIP  = sData:sub(85, 88),
    }
end

-- =============================================
-- FULL PACKET ASSEMBLY / DISASSEMBLY
-- =============================================

--- Build a complete IP packet (header + payload)
function IP.buildPacket(sSrc, sDst, nProto, sPayload, tOpts)
    tOpts = tOpts or {}
    local tH = {
        sSrc    = sSrc,
        sDst    = sDst,
        nProto  = nProto,
        nTTL    = tOpts.nTTL or IP.DEFAULT_TTL,
        nId     = tOpts.nId or math.random(0, 0xFFFF),
        nFlags  = tOpts.nFlags or 0,
        nFragOff = tOpts.nFragOff or 0,
        nDSCP   = tOpts.nDSCP or 0,
    }
    local sHdr = IP.packIPHeader(tH, #sPayload)
    return sHdr .. sPayload
end

--- Build complete TCP packet
function IP.buildTCPPacket(sSrc, sDst, tTCP, sData, tOpts)
    local sTcpSeg = IP.packTCPHeader(tTCP, sSrc, sDst, sData or "")
    return IP.buildPacket(sSrc, sDst, IP.PROTO_TCP, sTcpSeg, tOpts)
end

--- Build complete UDP packet
function IP.buildUDPPacket(sSrc, sDst, nSrcPort, nDstPort, sData, tOpts)
    local sUdpDgram = IP.packUDPHeader(
        {nSrcPort = nSrcPort, nDstPort = nDstPort},
        sSrc, sDst, sData or "")
    return IP.buildPacket(sSrc, sDst, IP.PROTO_UDP, sUdpDgram, tOpts)
end

--- Build ICMP echo request
function IP.buildPing(sSrc, sDst, nId, nSeq, sPayload, tOpts)
    local sIcmp = IP.packICMP(IP.ICMP_ECHO_REQUEST, 0, nId, nSeq, sPayload)
    return IP.buildPacket(sSrc, sDst, IP.PROTO_ICMP, sIcmp, tOpts)
end

--- Full packet parse: IP header → protocol-specific header → payload
function IP.parsePacket(sPacket)
    local tIP, sErr = IP.unpackIPHeader(sPacket)
    if not tIP then return nil, sErr end

    tIP.tTransport = nil

    if tIP.nProto == IP.PROTO_TCP then
        local tTCP = IP.unpackTCPHeader(tIP.sPayload, tIP.sSrc, tIP.sDst)
        if tTCP then tIP.tTransport = tTCP end
    elseif tIP.nProto == IP.PROTO_UDP then
        local tUDP = IP.unpackUDPHeader(tIP.sPayload, tIP.sSrc, tIP.sDst)
        if tUDP then tIP.tTransport = tUDP end
    elseif tIP.nProto == IP.PROTO_ICMP then
        local tICMP = IP.unpackICMP(tIP.sPayload)
        if tICMP then tIP.tTransport = tICMP end
    end

    return tIP
end

-- =============================================
-- ROUTING TABLE
-- Longest-prefix match, just like real routers
-- =============================================

IP.RoutingTable = {}
IP.RoutingTable.__index = IP.RoutingTable

function IP.RoutingTable.new()
    return setmetatable({
        tRoutes = {},  -- {sNetwork, sMask, nPrefix, sGateway, sInterface, nMetric}
    }, IP.RoutingTable)
end

function IP.RoutingTable:add(sCIDR, sGateway, sInterface, nMetric)
    local sNet, sMask, nPfx = IP.parseCIDR(sCIDR)
    if not sNet then return false, "invalid CIDR" end
    self.tRoutes[#self.tRoutes + 1] = {
        sNetwork   = IP.networkAddr(sNet, sMask),
        sMask      = sMask,
        nPrefix    = nPfx,
        sGateway   = sGateway and IP.parseAddr(sGateway),
        sInterface = sInterface,
        nMetric    = nMetric or 100,
    }
    -- Sort by prefix length (longest first), then metric
    table.sort(self.tRoutes, function(a, b)
        if a.nPrefix ~= b.nPrefix then return a.nPrefix > b.nPrefix end
        return a.nMetric < b.nMetric
    end)
    return true
end

function IP.RoutingTable:remove(sCIDR)
    local sNet, sMask, nPfx = IP.parseCIDR(sCIDR)
    if not sNet then return false end
    local sNorm = IP.networkAddr(sNet, sMask)
    for i = #self.tRoutes, 1, -1 do
        local r = self.tRoutes[i]
        if r.sNetwork == sNorm and r.nPrefix == nPfx then
            table.remove(self.tRoutes, i)
            return true
        end
    end
    return false
end

--- Longest-prefix match lookup
function IP.RoutingTable:lookup(sDstAddr)
    sDstAddr = IP.parseAddr(sDstAddr)
    if not sDstAddr then return nil end
    for _, r in ipairs(self.tRoutes) do
        if IP.isInSubnet(sDstAddr, r.sNetwork, r.sMask) then
            return r
        end
    end
    return nil  -- no route
end

function IP.RoutingTable:dump()
    local t = {}
    for _, r in ipairs(self.tRoutes) do
        t[#t + 1] = {
            network   = IP.formatAddr(r.sNetwork) .. "/" .. r.nPrefix,
            gateway   = r.sGateway and IP.formatAddr(r.sGateway) or "direct",
            interface = r.sInterface or "?",
            metric    = r.nMetric,
        }
    end
    return t
end

-- =============================================
-- ARP TABLE (IP → modem UUID mapping)
-- =============================================

IP.ARPTable = {}
IP.ARPTable.__index = IP.ARPTable

function IP.ARPTable.new()
    return setmetatable({
        tEntries = {},    -- [ip_binary] = {sHW, nExpiry, sState}
        nTimeout = 300,   -- 5 min ARP cache
    }, IP.ARPTable)
end

function IP.ARPTable:set(sIP, sHW, nTimeout)
    self.tEntries[sIP] = {
        sHW     = sHW,
        nExpiry = os.clock() + (nTimeout or self.nTimeout),
        sState  = "reachable",
    }
end

function IP.ARPTable:get(sIP)
    local e = self.tEntries[sIP]
    if not e then return nil end
    if os.clock() > e.nExpiry then
        self.tEntries[sIP] = nil
        return nil
    end
    return e.sHW
end

function IP.ARPTable:remove(sIP)
    self.tEntries[sIP] = nil
end

function IP.ARPTable:gc()
    local nNow = os.clock()
    for k, e in pairs(self.tEntries) do
        if nNow > e.nExpiry then self.tEntries[k] = nil end
    end
end

function IP.ARPTable:dump()
    local t = {}
    local nNow = os.clock()
    for sIP, e in pairs(self.tEntries) do
        t[#t + 1] = {
            ip    = IP.formatAddr(sIP),
            hw    = e.sHW,
            state = e.sState,
            ttl   = math.max(0, math.floor(e.nExpiry - nNow)),
        }
    end
    return t
end

-- =============================================
-- FRAGMENT REASSEMBLY
-- =============================================

IP.FragTable = {}
IP.FragTable.__index = IP.FragTable

function IP.FragTable.new(nTimeout)
    return setmetatable({
        tBuffers = {},   -- [key] = {tFrags, nLastSeen, nTotalLen}
        nTimeout = nTimeout or 30,
    }, IP.FragTable)
end

function IP.FragTable:_key(tIP)
    return tIP.sSrc .. tIP.sDst .. u16(tIP.nId) .. u8(tIP.nProto)
end

--- Add a fragment, returns complete payload if all received
function IP.FragTable:add(tIP)
    local sKey = self:_key(tIP)
    local nOff = tIP.nFragOff * 8  -- fragment offset in bytes

    if not self.tBuffers[sKey] then
        self.tBuffers[sKey] = {
            tFrags    = {},
            nLastSeen = os.clock(),
            nTotalLen = nil,
            tIPHdr    = tIP,
        }
    end

    local tBuf = self.tBuffers[sKey]
    tBuf.nLastSeen = os.clock()
    tBuf.tFrags[nOff] = tIP.sPayload

    -- Last fragment? Its offset + length = total
    if not tIP.bMF then
        tBuf.nTotalLen = nOff + #tIP.sPayload
    end

    -- Try to reassemble
    if tBuf.nTotalLen then
        local tData = {}
        local nPos = 0
        while nPos < tBuf.nTotalLen do
            local sFrag = tBuf.tFrags[nPos]
            if not sFrag then return nil end  -- missing fragment
            tData[#tData + 1] = sFrag
            nPos = nPos + #sFrag
        end
        -- Complete!
        self.tBuffers[sKey] = nil
        return table.concat(tData)
    end
    return nil  -- not yet complete
end

function IP.FragTable:gc()
    local nNow = os.clock()
    for k, tBuf in pairs(self.tBuffers) do
        if nNow - tBuf.nLastSeen > self.nTimeout then
            self.tBuffers[k] = nil
        end
    end
end

-- =============================================
-- IP PACKET IDENTIFICATION GENERATOR
-- =============================================

local g_nNextId = math.random(0, 0xFFFF)

function IP.nextId()
    g_nNextId = (g_nNextId + 1) % 0x10000
    return g_nNextId
end

-- =============================================
-- IP FRAGMENTATION
-- =============================================

--- Fragment a packet into MTU-sized pieces
function IP.fragment(sPacket, nMTU)
    local tIP = IP.unpackIPHeader(sPacket)
    if not tIP then return nil end
    if tIP.bDF then return nil, "DF set" end

    local nMaxPayload = nMTU - IP.MIN_IP_HEADER
    -- Fragment offset must be multiple of 8
    nMaxPayload = nMaxPayload - (nMaxPayload % 8)

    local sPayload = tIP.sPayload
    if #sPayload <= nMaxPayload then return {sPacket} end

    local tFrags = {}
    local nOff = 0

    while nOff < #sPayload do
        local nChunkLen = math.min(nMaxPayload, #sPayload - nOff)
        local bMore = (nOff + nChunkLen < #sPayload)

        -- Adjust last fragment (doesn't need 8-byte alignment)
        if not bMore and nChunkLen % 8 ~= 0 then
            -- OK, last fragment can be unaligned
        elseif bMore then
            nChunkLen = nChunkLen - (nChunkLen % 8)
        end

        local sChunk = sPayload:sub(nOff + 1, nOff + nChunkLen)
        local nFlags = bMore and 1 or 0  -- MF flag

        local sFrag = IP.buildPacket(tIP.sSrc, tIP.sDst, tIP.nProto, sChunk, {
            nTTL     = tIP.nTTL,
            nId      = tIP.nId,
            nFlags   = nFlags,
            nFragOff = nOff / 8,
            nDSCP    = tIP.nDSCP,
        })
        tFrags[#tFrags + 1] = sFrag
        nOff = nOff + nChunkLen
    end

    return tFrags
end

return IP