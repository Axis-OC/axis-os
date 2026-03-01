--
-- /usr/commands/dig.lua
-- AxisOS DNS Lookup Utility
--
-- Usage: dig <domain> [type]
--   dig example.com
--   dig example.com MX
--   dig example.com AAAA
--
local DNS  = require("net/dns")
local args = env.ARGS or {}
local C = {R="\27[37m",G="\27[32m",Y="\27[33m",C="\27[36m",D="\27[90m",E="\27[31m"}

local sDomain = args[1]
local sType   = (args[2] or "A"):upper()

if not sDomain then
    print(C.C.."dig"..C.R.." — DNS lookup utility")
    print("Usage: dig <domain> [type]")
    print("Types: A, AAAA, CNAME, MX, NS, TXT, PTR, SRV")
    return
end

local tTypeMap = {
    A=DNS.TYPE_A, NS=DNS.TYPE_NS, CNAME=DNS.TYPE_CNAME,
    MX=DNS.TYPE_MX, TXT=DNS.TYPE_TXT, AAAA=DNS.TYPE_AAAA,
    PTR=DNS.TYPE_PTR, SRV=DNS.TYPE_SRV,
}
local nType = tTypeMap[sType] or DNS.TYPE_A

print("")
print(C.D.."; <<>> AxisOS dig <<>> "..sDomain.." "..sType..C.R)
print(C.D.."; (1 server found)"..C.R)
print("")

local nStart = os.clock()
local tRecords, sErr = DNS.resolveHTTP(sDomain, nType)
local nElapsed = math.floor((os.clock() - nStart) * 1000)

if not tRecords then
    print(C.E..";; connection timed out; no servers could be reached"..C.R)
    print(C.E..";; Error: "..tostring(sErr)..C.R)
    return
end

print(";; ANSWER SECTION:")
if #tRecords == 0 then
    print(C.Y..";; (no records)"..C.R)
else
    for _, r in ipairs(tRecords) do
        local sData = r.sAddress or r.sTarget or r.sText or "?"
        if r.nType == DNS.TYPE_MX and r.nPreference then
            sData = tostring(r.nPreference).." "..sData
        end
        print(string.format("%s%-24s %s%-5d%s IN %-5s %s%s%s",
            C.G, r.sName or sDomain, C.D,
            r.nTTL or 0, C.R,
            r.sType or "?",
            C.Y, sData, C.R))
    end
end

print("")
print(C.D..string.format(";; Query time: %d msec", nElapsed)..C.R)
print(C.D..";; WHEN: "..os.date()..C.R)
print(C.D..";; MSG SIZE: ~"..tostring(#tRecords * 20 + 40)..C.R)

-- Show cache stats
local tCS = DNS.cacheStats()
print(C.D..";; Cache: "..tCS.nEntries.."/"..tCS.nMax.." entries"..C.R)