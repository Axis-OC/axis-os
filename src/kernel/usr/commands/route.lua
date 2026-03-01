--
-- /usr/commands/route.lua  
-- AxisOS IP Routing Table Display
--
local args = env.ARGS or {}
local C = {R="\27[37m",G="\27[32m",Y="\27[33m",C="\27[36m",D="\27[90m"}

print(C.C.."Kernel IP routing table"..C.R)
print(string.format("%-20s %-16s %-8s %s",
    "Destination", "Gateway", "Metric", "Iface"))

-- Try to get routes from stack
local bOk, oStack = pcall(require, "net/stack")
if bOk and oStack and oStack.getRoutes then
    local tRoutes = oStack.getRoutes()
    for _, r in ipairs(tRoutes) do
        print(string.format("%-20s %-16s %-8d %s",
            r.network, r.gateway, r.metric, r.interface))
    end
    if #tRoutes == 0 then
        print(C.D.."  (no routes configured)"..C.R)
    end
else
    print(C.D.."  (network stack not active)"..C.R)
    print(C.D.."  Configure interfaces in /etc/network.cfg"..C.R)
end