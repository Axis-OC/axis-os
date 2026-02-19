-- free - show memory usage with breakdown
local nTotal = computer.totalMemory()
local nFree = computer.freeMemory()
local nUsed = nTotal - nFree
local function fmt(n) return string.format("%.1f KB", n / 1024) end
local nPct = math.floor((nUsed / nTotal) * 100)

print(string.format("%-8s %10s %10s %10s %5s", "", "total", "used", "free", "use%"))
print(string.format("%-8s %10s %10s %10s %4d%%",
    "Mem:", fmt(nTotal), fmt(nUsed), fmt(nFree), nPct))

-- Visual bar
local nW = 30
local nFill = math.floor(nPct / 100 * nW)
local sC = "\27[32m"
if nPct > 80 then sC = "\27[31m" elseif nPct > 60 then sC = "\27[33m" end
print("")
print("  [" .. sC .. string.rep("#", nFill) .. "\27[90m" ..
    string.rep("-", nW - nFill) .. "\27[37m] " .. nPct .. "%")

if nFree < 32768 then
    print("\n  \27[31m⚠  LOW MEMORY\27[37m")
end