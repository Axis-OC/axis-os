--
-- /usr/commands/netdiag.lua
-- Network diagnostic tool
--
local fs = require("filesystem")
local C = {R="\27[37m",G="\27[32m",E="\27[31m",Y="\27[33m",C="\27[36m",D="\27[90m"}

print(C.C .. "AxisOS Network Diagnostic" .. C.R)
print("")

-- 1. Internet card
print(C.Y .. "1. Internet Card:" .. C.R)
local hNet = fs.open("/dev/net", "r")
if hNet then
    local bOk, tInfo = fs.deviceControl(hNet, "info", {})
    if bOk and tInfo then
        print("   Online:   " .. (tInfo.bOnline and (C.G.."YES") or (C.E.."NO")) .. C.R)
        print("   HTTP:     " .. (tInfo.bHttpEnabled and (C.G.."enabled") or (C.E.."disabled")) .. C.R)
        print("   TCP:      " .. (tInfo.bTcpEnabled and (C.G.."enabled") or (C.E.."disabled")) .. C.R)
        print("   Sessions: " .. tInfo.nActiveSessions .. "/" .. tInfo.nMaxSessions)
    end
    fs.close(hNet)
else
    print("   " .. C.E .. "Driver not loaded. Run: insmod internet" .. C.R)
end

-- 2. Modem NIC
print("")
print(C.Y .. "2. Modem NIC:" .. C.R)
local hNic = fs.open("/dev/nic0", "r")
if hNic then
    local bOk, tInfo = fs.deviceControl(hNic, "info", {})
    if bOk and tInfo then
        local bHasModem = tInfo.sModemAddr and tInfo.sModemAddr ~= ""
        print("   Modem:    " .. (bHasModem and (C.G..tInfo.sModemAddr:sub(1,13)) or (C.E.."NONE")) .. C.R)
        print("   Up:       " .. (tInfo.bUp and (C.G.."YES") or (C.E.."NO")) .. C.R)
        print("   MTU:      " .. tInfo.nMTU)
        print("   VLAN:     " .. tInfo.sVlanMode .. " native=" .. tInfo.nNativeVlan)
        if tInfo.tStats then
            print("   RX:       " .. tInfo.tStats.nRxPackets .. " pkts / " .. tInfo.tStats.nRxBytes .. " bytes")
            print("   TX:       " .. tInfo.tStats.nTxPackets .. " pkts / " .. tInfo.tStats.nTxBytes .. " bytes")
        end
        if not bHasModem then
            print("")
            print("   " .. C.Y .. "No modem component attached to this computer." .. C.R)
            print("   " .. C.D .. "The IP stack (ARP, routing, TCP/UDP over modem)" .. C.R)
            print("   " .. C.D .. "requires a modem card in the computer case." .. C.R)
        end
    end
    fs.close(hNic)
else
    print("   " .. C.E .. "Driver not loaded. Run: insmod modem" .. C.R)
end

-- 3. DNS test
print("")
print(C.Y .. "3. DNS Resolution:" .. C.R)
local bDnsOk, DNS = pcall(require, "net/dns")
if bDnsOk and DNS then
    local sIP, tRecs = DNS.resolve("example.com")
    if sIP then
        print("   example.com → " .. C.G .. sIP .. C.R)
    else
        print("   " .. C.E .. "FAILED" .. C.R .. " (internet card HTTP must be enabled)")
    end
    local tCS = DNS.cacheStats()
    print("   Cache: " .. tCS.nEntries .. "/" .. tCS.nMax)
else
    print("   " .. C.E .. "DNS library not available" .. C.R)
end

-- 4. HTTP connectivity test
print("")
print(C.Y .. "4. HTTP Connectivity:" .. C.R)
local bHttpOk, http = pcall(require, "http")
if bHttpOk and http then
    local tResp = http.get("http://example.com", nil, 5)
    if tResp and tResp.code == 200 then
        print("   HTTP GET: " .. C.G .. "200 OK" .. C.R .. " (" .. tResp.connectMs .. "ms)")
    elseif tResp then
        print("   HTTP GET: " .. C.Y .. tostring(tResp.code) .. C.R ..
              " " .. (tResp.error or tResp.message or ""))
    else
        print("   " .. C.E .. "No response" .. C.R)
    end
else
    print("   " .. C.E .. "HTTP library not available" .. C.R)
end

print("")
print(C.D .. "If internet card shows 'disabled', enable it in the" .. C.R)
print(C.D .. "OpenComputers server config (config/opencomputers.cfg):" .. C.R)
print(C.D .. "  enableHttp = true" .. C.R)
print(C.D .. "  enableTcp = true" .. C.R)