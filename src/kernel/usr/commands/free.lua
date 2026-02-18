-- free - show memory usage
local nTotal = computer.totalMemory()
local nFree = computer.freeMemory()
local nUsed = nTotal - nFree
local function fmt(n) return string.format("%.1f KB", n / 1024) end

print(string.format("%-8s %10s %10s %10s", "", "total", "used", "free"))
print(string.format("%-8s %10s %10s %10s", "Mem:", fmt(nTotal), fmt(nUsed), fmt(nFree)))
print(string.format("%-8s %s", "Usage:", string.format("%.1f%%", (nUsed / nTotal) * 100)))