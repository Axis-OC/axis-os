--
-- /usr/commands/nfw.lua
-- AxisOS Network Firewall Manager
-- (name inspired by ufw — "netfilter wrapper")
--
-- Usage:
--   nfw status               Show firewall status
--   nfw rules                List active rules
--   nfw hosts                List hosts file entries
--   nfw audit [count]        Show recent audit log
--   nfw stats                Per-process connection stats
--   nfw reload               Reload rules from disk
--   nfw enable / disable     Toggle firewall
--   nfw limit <n>            Set per-UID connection limit
--   nfw test <url>           Test if a URL would be allowed
--

local fs  = require("filesystem")
local tArgs = env.ARGS or {}

local C = {
  R = "\27[37m", GRN = "\27[32m", RED = "\27[31m",
  YLW = "\27[33m", CYN = "\27[36m", GRY = "\27[90m", MAG = "\27[35m",
}

local function netctl(sMethod, tMethodArgs)
  local hNet = fs.open("/dev/net", "r")
  if not hNet then return nil, "Cannot open /dev/net" end
  local bOk, tResult = fs.deviceControl(hNet, sMethod, tMethodArgs or {})
  fs.close(hNet)
  return bOk, tResult
end

local function cmd_status()
  print(C.CYN .. "AxisOS Network Firewall Status" .. C.R)
  print(C.GRY .. string.rep("-", 40) .. C.R)

  local bOk, tInfo = netctl("info", {})
  if bOk and tInfo then
    print("  Online:     " .. (tInfo.bOnline and (C.GRN .. "Yes") or (C.RED .. "No")) .. C.R)
    print("  HTTP:       " .. (tInfo.bHttpEnabled and (C.GRN .. "Yes") or (C.RED .. "No")) .. C.R)
    print("  TCP:        " .. (tInfo.bTcpEnabled and (C.GRN .. "Yes") or (C.RED .. "No")) .. C.R)
    print("  Sessions:   " .. tostring(tInfo.nActiveSessions) .. "/" .. tostring(tInfo.nMaxSessions))
  end

  -- Check if netfilter is loaded by trying to get rules
  local bRulesOk, tRules = netctl("nf_rules", {})
  if bRulesOk and tRules then
    print("  Firewall:   " .. C.GRN .. "Active" .. C.R)
    print("  Rules:      " .. #tRules)
  else
    print("  Firewall:   " .. C.YLW .. "Not loaded" .. C.R)
  end
end

local function cmd_rules()
  local bOk, tRules = netctl("nf_rules", {})
  if not bOk or not tRules then
    print(C.YLW .. "Firewall rules not available" .. C.R)
    return
  end

  print(C.CYN .. "Active Network Policy Rules" .. C.R)
  print(C.GRY .. string.rep("-", 70) .. C.R)
  print(string.format("  %s%-3s %-6s %-5s %-24s %-6s %-4s %s%s",
        C.GRY, "#", "ACTION", "PROTO", "HOST", "PORT", "RING", "COMMENT", C.R))

  for i, tRule in ipairs(tRules) do
    local sAC = C.GRN
    if tRule.action == "deny" then sAC = C.RED
    elseif tRule.action == "log" then sAC = C.YLW end

    local sHost = tostring(tRule.host or "*")
    if #sHost > 22 then sHost = sHost:sub(1, 19) .. "..." end

    print(string.format("  %-3d %s%-6s%s %-5s %-24s %-6s %-4s %s",
          i,
          sAC, tRule.action or "?", C.R,
          tRule.proto or "*",
          sHost,
          tostring(tRule.port or "*"),
          tostring(tRule.ring or "*"),
          C.GRY .. (tRule.comment or "") .. C.R))
  end
end

local function cmd_hosts()
  local bOk, tHosts = netctl("nf_hosts", {})
  if not bOk or not tHosts then
    print(C.YLW .. "Hosts file not loaded" .. C.R)
    return
  end

  print(C.CYN .. "Hosts Entries (/etc/hosts)" .. C.R)
  print(C.GRY .. string.rep("-", 50) .. C.R)

  local nCount = 0
  for sHost, sTarget in pairs(tHosts) do
    local sColor = C.GRN
    if sTarget == "0.0.0.0" or sTarget == "127.0.0.1" then
      sColor = C.RED
    end
    print(string.format("  %-30s -> %s%s%s", sHost, sColor, sTarget, C.R))
    nCount = nCount + 1
  end
  if nCount == 0 then print(C.GRY .. "  (empty)" .. C.R) end
end

local function cmd_audit(nMax)
  nMax = tonumber(nMax) or 20
  local bOk, tLog = netctl("nf_audit", {})
  if not bOk or not tLog then
    print(C.YLW .. "No audit log available" .. C.R)
    return
  end

  print(C.CYN .. "Network Audit Log (last " .. math.min(nMax, #tLog) .. ")" .. C.R)
  print(C.GRY .. string.rep("-", 70) .. C.R)

  local nStart = math.max(1, #tLog - nMax + 1)
  for i = nStart, #tLog do
    local e = tLog[i]
    local sAC = C.GRN
    if e.sAction:find("DENY") then sAC = C.RED
    elseif e.sAction:find("LOG") then sAC = C.YLW end

    print(string.format("  %s%.1f%s %s%-10s%s %-4s %-20s:%-5d PID=%-3d UID=%-3d %s",
          C.GRY, e.nTime, C.R,
          sAC, e.sAction, C.R,
          e.sProto,
          e.sHost, e.nPort,
          e.nPid, e.nUid,
          C.GRY .. e.sComment .. C.R))
  end
end

local function cmd_stats()
  local bOk, tStats = netctl("nf_stats", {})
  if not bOk or not tStats then
    print(C.YLW .. "No connection stats available" .. C.R)
    return
  end

  print(C.CYN .. "Per-Process Connection Statistics" .. C.R)
  print(C.GRY .. string.rep("-", 45) .. C.R)
  print(string.format("  %s%-5s %-5s %-8s %-12s%s",
        C.GRY, "PID", "UID", "ACTIVE", "TOTAL BYTES", C.R))

  for _, s in ipairs(tStats) do
    local sBytes
    if s.nBytes > 1048576 then
      sBytes = string.format("%.1f MB", s.nBytes / 1048576)
    elseif s.nBytes > 1024 then
      sBytes = string.format("%.1f KB", s.nBytes / 1024)
    else
      sBytes = s.nBytes .. " B"
    end
    print(string.format("  %-5d %-5d %-8d %-12s",
          s.nPid, s.nUid, s.nActive, sBytes))
  end
end

local function cmd_test(sUrl)
  if not sUrl then print("Usage: nfw test <url>"); return end
  print(C.CYN .. "Testing: " .. C.R .. sUrl)

  -- Extract host/port
  local sHost = sUrl:match("^https?://([^/:]+)") or sUrl:match("^([^/:]+)") or sUrl
  local nPort = tonumber(sUrl:match("^https?://[^/:]+:(%d+)")) or 80
  if sUrl:sub(1, 5) == "https" then nPort = 443 end

  print("  Host: " .. sHost)
  print("  Port: " .. nPort)

  -- We can't directly call the policy engine from userspace,
  -- but we can try a dry-run by checking hosts rewriting
  local bHostsOk, tHosts = netctl("nf_hosts", {})
  if bHostsOk and tHosts then
    local sTarget = tHosts[sHost]
    if sTarget then
      if sTarget == "0.0.0.0" or sTarget == "127.0.0.1" then
        print(C.RED .. "  BLOCKED by /etc/hosts" .. C.R)
        return
      else
        print(C.YLW .. "  Rewrites to: " .. sTarget .. C.R)
      end
    end
  end

  print(C.GRN .. "  Would be allowed (based on hosts file)" .. C.R)
  print(C.GRY .. "  Note: full policy check happens at connection time" .. C.R)
end

-- =============================================
-- DISPATCH
-- =============================================

if #tArgs < 1 then cmd_status(); return end

local sCmd = tArgs[1]

if sCmd == "status" then cmd_status()
elseif sCmd == "rules" then cmd_rules()
elseif sCmd == "hosts" then cmd_hosts()
elseif sCmd == "audit" then cmd_audit(tArgs[2])
elseif sCmd == "stats" then cmd_stats()
elseif sCmd == "test" then cmd_test(tArgs[2])

elseif sCmd == "reload" then
  local bOk, sMsg = netctl("nf_reload", {})
  if bOk then print(C.GRN .. "Rules and hosts reloaded" .. C.R)
  else print(C.RED .. "Reload failed" .. C.R) end

elseif sCmd == "enable" then
  netctl("nf_enable", {true})
  print(C.GRN .. "Firewall enabled" .. C.R)

elseif sCmd == "disable" then
  netctl("nf_enable", {false})
  print(C.YLW .. "Firewall disabled" .. C.R)

elseif sCmd == "limit" then
  local n = tonumber(tArgs[2])
  if n then
    netctl("nf_set_limit", {n})
    print("Connection limit set to " .. n .. " per UID")
  else
    print("Usage: nfw limit <number>")
  end

elseif sCmd == "-h" or sCmd == "--help" then
  print(C.CYN .. "nfw" .. C.R .. " - AxisOS Network Firewall Manager")
  print("")
  print("  nfw status             Firewall status")
  print("  nfw rules              List policy rules")
  print("  nfw hosts              List hosts entries")
  print("  nfw audit [n]          Recent audit log")
  print("  nfw stats              Per-process connection stats")
  print("  nfw reload             Reload rules from disk")
  print("  nfw enable/disable     Toggle firewall")
  print("  nfw limit <n>          Per-UID connection limit")
  print("  nfw test <url>         Test URL against policy")

else
  print(C.RED .. "Unknown command: " .. sCmd .. C.R)
  print("Use 'nfw --help' for usage")
end