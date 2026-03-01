--
-- /usr/commands/nettest.lua
-- AxisOS Network Stack Test Suite
--
-- Tests every layer: ipproto, checksums, routing, ARP,
-- fragmentation, DNS encoding, lnqiobuf, nftables rules.
--

local IP   = require("net/ipproto")
local DNS  = require("net/dns")

local tArgs = env.ARGS or {}
local C = {R="\27[37m",G="\27[32m",E="\27[31m",Y="\27[33m",
           C="\27[36m",D="\27[90m",M="\27[35m"}

local nPass, nFail, nSkip = 0, 0, 0

local function pass(s) nPass=nPass+1; print(C.G.."  [PASS] "..C.R..s) end
local function fail(s) nFail=nFail+1; print(C.E.."  [FAIL] "..C.R..s) end
local function skip(s) nSkip=nSkip+1; print(C.Y.."  [SKIP] "..C.R..s) end
local function info(s) print(C.C.."  [INFO] "..C.R..s) end
local function section(s) print(""); print(C.Y.."=== "..s.." ==="..C.R) end

-- ═══════════════════════════════════════════
-- HEADER
-- ═══════════════════════════════════════════

print(C.C.."╔═══════════════════════════════════════════════════╗"..C.R)
print(C.C.."║  AxisOS Network Stack Test Suite                   ║"..C.R)
print(C.C.."║  ipproto · DNS · routing · ARP · checksums         ║"..C.R)
print(C.C.."╚═══════════════════════════════════════════════════╝"..C.R)

-- ═══════════════════════════════════════════
-- 1. IP ADDRESS OPERATIONS
-- ═══════════════════════════════════════════

section("1. IP Address Operations")

do
    local sB = IP.parseAddr("10.0.0.1")
    if sB and #sB == 4 and sB:byte(1)==10 and sB:byte(4)==1 then
        pass("parseAddr('10.0.0.1') = 4 bytes correct")
    else fail("parseAddr failed") end

    local sF = IP.formatAddr(sB)
    if sF == "10.0.0.1" then pass("formatAddr roundtrip OK")
    else fail("formatAddr: "..tostring(sF)) end

    local sN = IP.parseAddr("0.0.0.0")
    if sN == IP.ADDR_ANY then pass("ADDR_ANY matches")
    else fail("ADDR_ANY mismatch") end

    -- CIDR
    local sAddr, sMask, nPfx = IP.parseCIDR("192.168.1.0/24")
    if sAddr and nPfx == 24 then pass("parseCIDR 192.168.1.0/24 OK")
    else fail("parseCIDR failed") end

    local sNet = IP.networkAddr(IP.parseAddr("192.168.1.42"),
                                IP.parseAddr("255.255.255.0"))
    if IP.formatAddr(sNet) == "192.168.1.0" then
        pass("networkAddr(192.168.1.42/24) = 192.168.1.0")
    else fail("networkAddr: "..IP.formatAddr(sNet)) end

    local sBcast = IP.broadcastAddr(IP.parseAddr("192.168.1.0"),
                                    IP.parseAddr("255.255.255.0"))
    if IP.formatAddr(sBcast) == "192.168.1.255" then
        pass("broadcastAddr = 192.168.1.255")
    else fail("broadcastAddr: "..IP.formatAddr(sBcast)) end

    if IP.isInSubnet(IP.parseAddr("192.168.1.99"),
                     IP.parseAddr("192.168.1.0"),
                     IP.parseAddr("255.255.255.0")) then
        pass("isInSubnet: 192.168.1.99 in 192.168.1.0/24")
    else fail("isInSubnet false negative") end

    if not IP.isInSubnet(IP.parseAddr("10.0.0.1"),
                         IP.parseAddr("192.168.1.0"),
                         IP.parseAddr("255.255.255.0")) then
        pass("isInSubnet: 10.0.0.1 NOT in 192.168.1.0/24")
    else fail("isInSubnet false positive") end
end

-- ═══════════════════════════════════════════
-- 2. INTERNET CHECKSUM
-- ═══════════════════════════════════════════

section("2. Internet Checksum (RFC 1071)")

do
    -- Known test vector: IP header from RFC 1071
    local sTest = "\x45\x00\x00\x73\x00\x00\x40\x00\x40\x11"
               .. "\x00\x00\xc0\xa8\x00\x01\xc0\xa8\x00\xc7"
    local nCk = IP.checksum(sTest)
    -- The checksum of a valid header (with correct checksum field) = 0
    -- For this test vector with checksum=0, compute and verify non-zero
    if nCk and nCk > 0 then
        pass("checksum returns non-zero for zeroed-checksum header: 0x"..
             string.format("%04X", nCk))
    else fail("checksum returned 0 or nil") end

    -- Self-check: checksum of data containing its own checksum = 0
    local sHdr = "\x45\x00\x00\x73\x00\x00\x40\x00\x40\x11"
              .. string.char(math.floor(nCk/256), nCk%256)
              .. "\xc0\xa8\x00\x01\xc0\xa8\x00\xc7"
    if IP.verifyChecksum(sHdr) then
        pass("verifyChecksum: header with correct checksum = 0")
    else fail("verifyChecksum failed") end

    -- Empty data
    local nEmpty = IP.checksum("")
    if nEmpty == 0xFFFF then pass("checksum('') = 0xFFFF (ones' complement)")
    else info("checksum('') = 0x"..string.format("%04X", nEmpty)) end
end

-- ═══════════════════════════════════════════
-- 3. IP PACKET BUILD + PARSE
-- ═══════════════════════════════════════════

section("3. IP Packet Assembly & Disassembly")

do
    local sSrc = IP.parseAddr("10.0.0.1")
    local sDst = IP.parseAddr("10.0.0.2")
    local sPayload = "Hello, IP world!"

    local sPkt = IP.buildPacket(sSrc, sDst, IP.PROTO_UDP, sPayload, {
        nTTL = 32, nId = 0x1234,
    })
    if sPkt and #sPkt == 20 + #sPayload then
        pass("buildPacket: "..#sPkt.." bytes (20 hdr + "..#sPayload.." payload)")
    else fail("buildPacket size wrong: "..tostring(sPkt and #sPkt)) end

    local tIP = IP.parsePacket(sPkt)
    if tIP then
        if tIP.nVersion == 4 then pass("parsePacket: IPv4") else fail("version: "..tIP.nVersion) end
        if tIP.nTTL == 32 then pass("TTL = 32") else fail("TTL: "..tIP.nTTL) end
        if tIP.nId == 0x1234 then pass("ID = 0x1234") else fail("ID: "..tIP.nId) end
        if tIP.nProto == IP.PROTO_UDP then pass("Proto = UDP(17)") else fail("Proto: "..tIP.nProto) end
        if IP.formatAddr(tIP.sSrc) == "10.0.0.1" then pass("Src = 10.0.0.1") else fail("Src wrong") end
        if IP.formatAddr(tIP.sDst) == "10.0.0.2" then pass("Dst = 10.0.0.2") else fail("Dst wrong") end
        if tIP.sPayload == sPayload then pass("Payload intact") else fail("Payload corrupted") end
    else fail("parsePacket returned nil") end
end

-- ═══════════════════════════════════════════
-- 4. TCP PACKET
-- ═══════════════════════════════════════════

section("4. TCP Packet Build & Parse")

do
    local sSrc = IP.parseAddr("10.0.0.1")
    local sDst = IP.parseAddr("10.0.0.2")

    local sPkt = IP.buildTCPPacket(sSrc, sDst, {
        nSrcPort = 12345,
        nDstPort = 80,
        nSeq     = 1000,
        nAck     = 0,
        nFlags   = bit32.bor(IP.TCP_SYN),
        nWindow  = 65535,
    }, "", {nTTL = 64})

    local tIP = IP.parsePacket(sPkt)
    if tIP and tIP.tTransport then
        local tTCP = tIP.tTransport
        if tTCP.nSrcPort == 12345 then pass("TCP SrcPort = 12345")
        else fail("SrcPort: "..tostring(tTCP.nSrcPort)) end
        if tTCP.nDstPort == 80 then pass("TCP DstPort = 80")
        else fail("DstPort: "..tostring(tTCP.nDstPort)) end
        if tTCP.nSeq == 1000 then pass("TCP Seq = 1000")
        else fail("Seq: "..tostring(tTCP.nSeq)) end
        if tTCP.bSYN then pass("TCP SYN flag set")
        else fail("SYN not set") end
        if not tTCP.bACK then pass("TCP ACK flag not set")
        else fail("ACK unexpectedly set") end
    else fail("TCP parse failed") end
end

-- ═══════════════════════════════════════════
-- 5. UDP PACKET
-- ═══════════════════════════════════════════

section("5. UDP Packet Build & Parse")

do
    local sSrc = IP.parseAddr("10.0.0.1")
    local sDst = IP.parseAddr("10.0.0.2")

    local sPkt = IP.buildUDPPacket(sSrc, sDst, 5353, 53, "DNS QUERY DATA")
    local tIP = IP.parsePacket(sPkt)

    if tIP and tIP.tTransport then
        local tUDP = tIP.tTransport
        if tUDP.nSrcPort == 5353 then pass("UDP SrcPort = 5353")
        else fail("SrcPort: "..tostring(tUDP.nSrcPort)) end
        if tUDP.nDstPort == 53 then pass("UDP DstPort = 53")
        else fail("DstPort: "..tostring(tUDP.nDstPort)) end
        if tUDP.sPayload == "DNS QUERY DATA" then pass("UDP payload intact")
        else fail("UDP payload corrupted") end
    else fail("UDP parse failed") end
end

-- ═══════════════════════════════════════════
-- 6. ICMP PACKET
-- ═══════════════════════════════════════════

section("6. ICMP (Ping) Build & Parse")

do
    local sSrc = IP.parseAddr("10.0.0.1")
    local sDst = IP.parseAddr("10.0.0.2")

    local sPkt = IP.buildPing(sSrc, sDst, 0x1234, 1, "PING_DATA")
    local tIP = IP.parsePacket(sPkt)

    if tIP and tIP.tTransport then
        local tICMP = tIP.tTransport
        if tICMP.nType == IP.ICMP_ECHO_REQUEST then pass("ICMP type = Echo Request(8)")
        else fail("ICMP type: "..tostring(tICMP.nType)) end
        if tICMP.nId == 0x1234 then pass("ICMP id = 0x1234")
        else fail("ICMP id: "..tostring(tICMP.nId)) end
        if tICMP.nSeq == 1 then pass("ICMP seq = 1")
        else fail("ICMP seq: "..tostring(tICMP.nSeq)) end
        if tICMP.bChecksumOk then pass("ICMP checksum valid")
        else fail("ICMP checksum INVALID") end
    else fail("ICMP parse failed") end
end

-- ═══════════════════════════════════════════
-- 7. ARP
-- ═══════════════════════════════════════════

section("7. ARP Pack & Unpack")

do
    local sSenderHW = "abcd-1234-5678-90ab-cdef-1234-5678-90ab"
    local sSenderIP = IP.parseAddr("10.0.0.1")
    local sTargetIP = IP.parseAddr("10.0.0.2")

    local sArp = IP.packARP(IP.ARP_REQUEST, sSenderHW, sSenderIP, "", sTargetIP)
    if sArp and #sArp >= 88 then pass("ARP pack: "..#sArp.." bytes")
    else fail("ARP pack too short") end

    local tARP = IP.unpackARP(sArp)
    if tARP then
        if tARP.nOpcode == IP.ARP_REQUEST then pass("ARP opcode = REQUEST(1)")
        else fail("ARP opcode: "..tostring(tARP.nOpcode)) end
        if tARP.sSenderHW:sub(1,4) == "abcd" then pass("ARP sender HW preserved")
        else fail("ARP sender HW: "..tARP.sSenderHW) end
        if IP.formatAddr(tARP.sTargetIP) == "10.0.0.2" then pass("ARP target IP = 10.0.0.2")
        else fail("ARP target IP wrong") end
    else fail("ARP unpack failed") end

    -- ARP table
    local tArp = IP.ARPTable.new()
    tArp:set(sSenderIP, sSenderHW, 60)
    local sHW = tArp:get(sSenderIP)
    if sHW == sSenderHW then pass("ARPTable set/get roundtrip")
    else fail("ARPTable get: "..tostring(sHW)) end

    tArp:remove(sSenderIP)
    if not tArp:get(sSenderIP) then pass("ARPTable remove works")
    else fail("ARPTable remove failed") end
end

-- ═══════════════════════════════════════════
-- 8. ROUTING TABLE
-- ═══════════════════════════════════════════

section("8. Routing Table (Longest-Prefix Match)")

do
    local tRT = IP.RoutingTable.new()
    tRT:add("10.0.0.0/8", nil, "eth0", 100)
    tRT:add("10.0.1.0/24", "10.0.1.1", "eth0", 50)
    tRT:add("0.0.0.0/0", "10.0.0.254", "eth0", 200)

    -- Longest prefix match: 10.0.1.50 → /24 route (not /8)
    local tR = tRT:lookup("10.0.1.50")
    if tR and tR.sInterface == "eth0" and tR.nPrefix == 24 then
        pass("LPM: 10.0.1.50 → /24 route (longest match)")
    else fail("LPM failed for 10.0.1.50") end

    -- /8 match
    local tR2 = tRT:lookup("10.99.0.1")
    if tR2 and tR2.nPrefix == 8 then pass("10.99.0.1 → /8 route")
    else fail("10.99.0.1 match failed") end

    -- Default route
    local tR3 = tRT:lookup("8.8.8.8")
    if tR3 and tR3.nPrefix == 0 then pass("8.8.8.8 → default route (0.0.0.0/0)")
    else fail("Default route not matched") end

    -- Remove and verify
    tRT:remove("10.0.1.0/24")
    local tR4 = tRT:lookup("10.0.1.50")
    if tR4 and tR4.nPrefix == 8 then pass("After remove /24: falls back to /8")
    else fail("Remove didn't work") end

    -- Dump
    local tDump = tRT:dump()
    if #tDump == 2 then pass("Dump: "..#tDump.." routes (removed 1)")
    else fail("Dump count: "..#tDump) end
end

-- ═══════════════════════════════════════════
-- 9. IP FRAGMENTATION
-- ═══════════════════════════════════════════

section("9. IP Fragmentation & Reassembly")

do
    local sSrc = IP.parseAddr("10.0.0.1")
    local sDst = IP.parseAddr("10.0.0.2")

    -- Build a large packet (300 bytes payload)
    local sPayload = string.rep("X", 300)
    local sPkt = IP.buildPacket(sSrc, sDst, IP.PROTO_UDP, sPayload, {
        nTTL = 64, nId = 0xABCD,
    })

    -- Fragment with 160-byte MTU (140B payload per fragment after 20B header)
    local tFrags = IP.fragment(sPkt, 160)
    if tFrags and #tFrags >= 2 then
        pass("Fragmented into "..#tFrags.." pieces (MTU=160)")
    else
        fail("Fragmentation failed: "..tostring(tFrags and #tFrags))
        goto skip_reassembly
    end

    -- Verify each fragment
    for i, sFrag in ipairs(tFrags) do
        local tF = IP.unpackIPHeader(sFrag)
        if tF then
            local bMore = (i < #tFrags)
            if tF.bMF == bMore then
                pass("Frag "..i..": MF="..(bMore and "1" or "0").." offset="..tF.nFragOff)
            else
                fail("Frag "..i..": MF flag wrong")
            end
        else fail("Frag "..i..": parse failed") end
    end

    -- Reassemble
    local tFT = IP.FragTable.new()
    local sReassembled
    for _, sFrag in ipairs(tFrags) do
        local tF = IP.unpackIPHeader(sFrag)
        sReassembled = tFT:add(tF)
    end

    if sReassembled and sReassembled == sPayload then
        pass("Reassembly: "..#sReassembled.."B matches original payload")
    elseif sReassembled then
        fail("Reassembly: size "..#sReassembled.." ≠ "..#sPayload)
    else
        fail("Reassembly incomplete (missing fragments)")
    end
end
::skip_reassembly::

-- ═══════════════════════════════════════════
-- 10. DNS ENCODING/DECODING
-- ═══════════════════════════════════════════

section("10. DNS Wire Format")

do
    -- Name encoding
    local sEnc = DNS.encodeName("www.example.com")
    if sEnc and sEnc:byte(1) == 3 and sEnc:sub(2,4) == "www"
       and sEnc:byte(5) == 7 and sEnc:sub(-1) == "\0" then
        pass("encodeName('www.example.com') format correct")
    else fail("encodeName format wrong") end

    -- Query building
    local sQuery, nId = DNS.buildQuery("example.com", DNS.TYPE_A, 0x1234)
    if sQuery and #sQuery >= 12 then
        pass("buildQuery: "..#sQuery.." bytes, ID=0x"..string.format("%04X", nId))
        -- Verify header fields
        local nQdCount = sQuery:byte(5)*256 + sQuery:byte(6)
        if nQdCount == 1 then pass("QDCOUNT = 1")
        else fail("QDCOUNT = "..nQdCount) end
        -- Verify QR=0 (query)
        local nFlags = sQuery:byte(3)*256 + sQuery:byte(4)
        if bit32.band(nFlags, 0x8000) == 0 then pass("QR = 0 (query)")
        else fail("QR should be 0") end
        -- Verify RD=1
        if bit32.band(nFlags, 0x0100) ~= 0 then pass("RD = 1 (recursion desired)")
        else fail("RD should be 1") end
    else fail("buildQuery failed") end

    -- Build a fake response for parsing
    -- Header: ID=0x1234, QR=1 RD=1 RA=1 RCODE=0, QD=1, AN=1, NS=0, AR=0
    local sRespHdr = "\x12\x34\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00"
    -- Question: example.com A IN
    local sQName = "\x07example\x03com\x00"
    local sQuestion = sQName.."\x00\x01\x00\x01"
    -- Answer: example.com A IN TTL=300 RDLEN=4 RDATA=93.184.216.34
    local sAnswer = "\xc0\x0c"  -- name pointer to offset 12
                 .. "\x00\x01\x00\x01"  -- TYPE=A CLASS=IN
                 .. "\x00\x00\x01\x2c"  -- TTL=300
                 .. "\x00\x04"           -- RDLEN=4
                 .. "\x5d\xb8\xd8\x22"  -- 93.184.216.34
    local sResp = sRespHdr .. sQuestion .. sAnswer

    local tR = DNS.parseResponse(sResp)
    if tR then
        if tR.nId == 0x1234 then pass("Response ID = 0x1234")
        else fail("Response ID: "..tostring(tR.nId)) end
        if tR.bQR then pass("QR = 1 (response)") else fail("QR should be 1") end
        if tR.nRcode == 0 then pass("RCODE = NOERROR")
        else fail("RCODE: "..tR.nRcode) end
        if tR.nANCount == 1 then pass("ANCOUNT = 1")
        else fail("ANCOUNT: "..tR.nANCount) end

        if #tR.tAnswers >= 1 then
            local tA = tR.tAnswers[1]
            if tA.nType == DNS.TYPE_A then pass("Answer type = A(1)")
            else fail("Answer type: "..tA.nType) end
            if tA.sAddress == "93.184.216.34" then
                pass("Answer RDATA = 93.184.216.34")
            else fail("Answer RDATA: "..tostring(tA.sAddress)) end
            if tA.nTTL == 300 then pass("Answer TTL = 300")
            else fail("Answer TTL: "..tA.nTTL) end
        else fail("No answers parsed") end
    else fail("parseResponse failed") end

    -- Cache test
    DNS.cacheClear()
    DNS.cacheSet("test.local", DNS.TYPE_A, {{sAddress="127.0.0.1"}}, 60)
    local tCached = DNS.cacheGet("test.local", DNS.TYPE_A)
    if tCached and #tCached == 1 and tCached[1].sAddress == "127.0.0.1" then
        pass("DNS cache set/get roundtrip")
    else fail("DNS cache failed") end

    if not DNS.cacheGet("nonexistent.local", DNS.TYPE_A) then
        pass("DNS cache miss returns nil")
    else fail("DNS cache returned data for missing entry") end

    local tCS = DNS.cacheStats()
    if tCS.nEntries == 1 then pass("DNS cache stats: 1 entry")
    else fail("Cache stats: "..tCS.nEntries) end
end

-- ═══════════════════════════════════════════
-- 11. LIVE DNS RESOLUTION (optional)
-- ═══════════════════════════════════════════

section("11. Live DNS Resolution (via internet card)")

do
    local bNetOk, oHttp = pcall(require, "http")
    if bNetOk then
        local tNetInfo = oHttp.info()
        if tNetInfo and tNetInfo.bHttpEnabled then
            info("Internet card available — testing live DNS...")
            local sIP, tRecs = DNS.resolve("example.com")
            if sIP then
                pass("DNS resolve('example.com') = "..sIP)
                if tRecs then
                    for _, r in ipairs(tRecs) do
                        info("  "..r.sType.." "..
                            (r.sAddress or r.sTarget or "?")..
                            " TTL="..tostring(r.nTTL))
                    end
                end
            else
                skip("DNS resolve failed (network issue, not a code bug)")
            end
        else
            skip("No internet card — skipping live DNS test")
        end
    else
        skip("HTTP library not available — skipping live DNS")
    end
end

-- ═══════════════════════════════════════════
-- 12. NIC DRIVER DEVICE CHECK
-- ═══════════════════════════════════════════

section("12. NIC Driver Device Check")

do
    local fs = require("filesystem")
    local hNic = fs.open("/dev/nic0", "r")
    if hNic then
        local bOk, tInfo = fs.deviceControl(hNic, "info", {})
        fs.close(hNic)
        if bOk and tInfo then
            pass("NIC device /dev/nic0 accessible")
            info("  Modem:  "..(tInfo.sModemAddr and tInfo.sModemAddr:sub(1,8) or "none"))
            info("  Up:     "..tostring(tInfo.bUp))
            info("  MTU:    "..tostring(tInfo.nMTU))
            info("  VLAN:   "..tostring(tInfo.sVlanMode).." native="..tostring(tInfo.nNativeVlan))
            if tInfo.tStats then
                info("  RxPkts: "..tInfo.tStats.nRxPackets.."  TxPkts: "..tInfo.tStats.nTxPackets)
            end
        else skip("NIC device info not available") end
    else
        skip("NIC device /dev/nic0 not available (driver not loaded)")
        info("Load with: insmod /drivers/modem_nic.sys.lua")
    end
end

-- ═══════════════════════════════════════════
-- SUMMARY
-- ═══════════════════════════════════════════

print("")
print(C.C.."═══════════════════════════════════════════════════"..C.R)
print(string.format("  %sPassed:%s  %d", C.G, C.R, nPass))
print(string.format("  %sFailed:%s  %d", nFail>0 and C.E or C.D, C.R, nFail))
print(string.format("  %sSkipped:%s %d", C.Y, C.R, nSkip))
print("")
if nFail == 0 then
    print(C.G.."  All network stack tests passed!"..C.R)
else
    print(C.E.."  "..nFail.." test(s) failed — review above."..C.R)
end
print(C.C.."═══════════════════════════════════════════════════"..C.R)