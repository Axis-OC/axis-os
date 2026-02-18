--
-- /usr/commands/ping.lua
-- TCP-based ping (ICMP not available in OpenComputers)
--
-- Usage: ping [-c count] [-p port] [-t timeout] <host>
--

local net = require("net")
local tArgs = env.ARGS or {}

local C = {
  R = "\27[37m", GRN = "\27[32m", RED = "\27[31m",
  YLW = "\27[33m", CYN = "\27[36m", GRY = "\27[90m",
}

-- parse args
local sHost    = nil
local nCount   = 4
local nPort    = 80
local nTimeout = 5

local i = 1
while i <= #tArgs do
  local a = tArgs[i]
  if a == "-c" then
    i = i + 1; nCount = tonumber(tArgs[i]) or 4
  elseif a == "-p" then
    i = i + 1; nPort = tonumber(tArgs[i]) or 80
  elseif a == "-t" then
    i = i + 1; nTimeout = tonumber(tArgs[i]) or 5
  elseif a == "-h" or a == "--help" then
    print("Usage: ping [-c count] [-p port] [-t timeout] <host>")
    print("  Simulates ICMP ping via TCP connect timing.")
    return
  elseif a:sub(1, 1) ~= "-" then
    sHost = a
  end
  i = i + 1
end

if not sHost then
  print("Usage: ping <host>")
  return
end

print(string.format("%sPING%s %s via TCP port %d (%d probes, %ds timeout)",
      C.CYN, C.R, sHost, nPort, nCount, nTimeout))
print("")

local tResult, sErr = net.ping(sHost, nPort, nCount, nTimeout)

if not tResult then
  print(C.RED .. "Error: " .. C.R .. tostring(sErr))
  return
end

-- individual results
for _, tProbe in ipairs(tResult.tResults or {}) do
  if tProbe.sStatus == "ok" then
    print(string.format("  seq=%d  %s%d ms%s  port=%d",
          tProbe.nSeq, C.GRN, tProbe.nMs, C.R, nPort))
  elseif tProbe.sStatus == "timeout" then
    print(string.format("  seq=%d  %s* timeout *%s  (%d ms)",
          tProbe.nSeq, C.YLW, C.R, tProbe.nMs or 0))
  else
    print(string.format("  seq=%d  %s! error: %s%s",
          tProbe.nSeq, C.RED, tostring(tProbe.sError), C.R))
  end
end

-- summary
print("")
print(string.format("--- %s ping statistics ---", sHost))
print(string.format("%d probes sent, %d received, %s%d%% loss%s",
      tResult.nSent, tResult.nRecv,
      tResult.nLoss > 0 and C.RED or C.GRN,
      tResult.nLoss, C.R))

if tResult.nRecv > 0 then
  print(string.format("rtt min/avg/max = %s%d/%d/%d ms%s",
        C.CYN, tResult.nMinMs, tResult.nAvgMs, tResult.nMaxMs, C.R))
end