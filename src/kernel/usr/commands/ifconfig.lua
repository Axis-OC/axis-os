--
-- /usr/commands/ifconfig.lua
-- AxisOS Network Interface Configuration
--
local fs = require("filesystem")
local args = env.ARGS or {}
local C = {R="\27[37m",G="\27[32m",Y="\27[33m",C="\27[36m",D="\27[90m"}

local function getNicInfo()
    local h = fs.open("/dev/nic0", "r")
    if not h then return nil end
    local bOk, tInfo = fs.deviceControl(h, "info", {})
    fs.close(h)
    return bOk and tInfo or nil
end

local function getNetInfo()
    local h = fs.open("/dev/net", "r")
    if not h then return nil end
    local bOk, tInfo = fs.deviceControl(h, "info", {})
    fs.close(h)
    return bOk and tInfo or nil
end

if not args[1] or args[1] == "-a" then
    -- Show all interfaces
    print(C.C.."eth0"..C.R..": Modem NIC")
    local tNic = getNicInfo()
    if tNic then
        print("    HWaddr "..C.Y..(tNic.sModemAddr or "none"):sub(1,13)..C.R)
        print("    Status: "..(tNic.bUp and (C.G.."UP") or (C.Y.."DOWN"))..C.R..
              "  MTU: "..tostring(tNic.nMTU))
        print("    VLAN:   "..tNic.sVlanMode.." native="..tostring(tNic.nNativeVlan))
        if tNic.tStats then
            local s = tNic.tStats
            print(string.format("    RX packets:%d bytes:%d dropped:%d errors:%d",
                s.nRxPackets, s.nRxBytes, s.nRxDropped, s.nRxErrors))
            print(string.format("    TX packets:%d bytes:%d dropped:%d errors:%d",
                s.nTxPackets, s.nTxBytes, s.nTxDropped, s.nTxErrors))
        end
    else
        print("    "..C.D.."(NIC driver not loaded)"..C.R)
    end
    print("")
    print(C.C.."inet0"..C.R..": Internet Card")
    local tNet = getNetInfo()
    if tNet then
        print("    HTTP: "..(tNet.bHttpEnabled and C.G.."enabled" or C.Y.."disabled")..C.R)
        print("    TCP:  "..(tNet.bTcpEnabled and C.G.."enabled" or C.Y.."disabled")..C.R)
        print("    Sessions: "..tostring(tNet.nActiveSessions).."/"..tostring(tNet.nMaxSessions))
    else
        print("    "..C.D.."(internet driver not loaded)"..C.R)
    end

elseif args[1] == "up" then
    local h = fs.open("/dev/nic0", "r")
    if h then
        fs.deviceControl(h, "set_up", {true})
        fs.close(h)
        print(C.G.."eth0 UP"..C.R)
    else print("No NIC device") end

elseif args[1] == "down" then
    local h = fs.open("/dev/nic0", "r")
    if h then
        fs.deviceControl(h, "set_up", {false})
        fs.close(h)
        print(C.Y.."eth0 DOWN"..C.R)
    else print("No NIC device") end

else
    print("Usage: ifconfig [-a|up|down]")
end