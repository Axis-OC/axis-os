--
-- /usr/commands/arp.lua
-- AxisOS ARP Table Display
--
local C = {R="\27[37m",G="\27[32m",Y="\27[33m",C="\27[36m",D="\27[90m"}

print(C.C.."ARP Table"..C.R)
print(string.format("%-16s %-38s %-12s %s",
    "Address", "HWaddr", "State", "TTL"))

local bOk, oStack = pcall(require, "net/stack")
if bOk and oStack and oStack.getArpTable then
    local tArp = oStack.getArpTable()
    for _, e in ipairs(tArp) do
        print(string.format("%-16s %-38s %-12s %ds",
            e.ip, e.hw:sub(1,36), e.state, e.ttl))
    end
    if #tArp == 0 then
        print(C.D.."  (ARP table empty)"..C.R)
    end
else
    print(C.D.."  (network stack not active)"..C.R)
end