-- uptime - show system uptime
local n = computer.uptime()
print(string.format("up %d:%02d:%02d",
  math.floor(n / 3600),
  math.floor((n % 3600) / 60),
  math.floor(n % 60)))