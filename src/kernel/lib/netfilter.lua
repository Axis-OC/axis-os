--
-- /lib/netfilter.lua
-- AxisOS Application-Level Network Policy Engine
-- Loaded by the internet driver at boot.
-- Provides: rule matching, connection tracking, host rewriting, audit logging.
--

local oNF = {}

-- =============================================
-- STATE
-- =============================================

local g_tRules = {}
local g_tHosts = {}
local g_tConnTracker = {}     -- [nPid] = { nCount, nBytes, tConns }
local g_tAuditLog = {}
local g_nMaxAuditEntries = 200
local g_bEnabled = true

-- Per-UID connection limits
local g_nMaxSessionsPerUid = 10

-- =============================================
-- LOADING
-- =============================================

function oNF.LoadRules(sCode)
  if not sCode or #sCode == 0 then
    g_tRules = {{ action = "allow", proto = "any", host = "*", port = "*", ring = "*" }}
    return true
  end
  local f = load(sCode, "netpolicy", "t", {})
  if f then
    local bOk, tResult = pcall(f)
    if bOk and type(tResult) == "table" then
      g_tRules = tResult
      return true
    end
  end
  return false
end

function oNF.LoadHosts(sCode)
  if not sCode or #sCode == 0 then
    g_tHosts = {}
    return true
  end
  local f = load(sCode, "hosts", "t", {})
  if f then
    local bOk, tResult = pcall(f)
    if bOk and type(tResult) == "table" then
      g_tHosts = tResult
      return true
    end
  end
  return false
end

function oNF.SetEnabled(b) g_bEnabled = b end
function oNF.IsEnabled() return g_bEnabled end

-- =============================================
-- HOST RESOLUTION
-- =============================================

-- Extract hostname from a URL
local function fExtractHost(sUrl)
  -- http://host:port/path or https://host/path or host:port
  local sHost = sUrl:match("^https?://([^/:]+)")
  if not sHost then
    sHost = sUrl:match("^([^/:]+)")
  end
  return sHost
end

-- Extract port from URL or default
local function fExtractPort(sUrl)
  local sPort = sUrl:match("^https?://[^/:]+:(%d+)")
  if sPort then return tonumber(sPort) end
  if sUrl:sub(1, 5) == "https" then return 443 end
  return 80
end

-- Rewrite URL based on /etc/hosts
function oNF.RewriteHost(sUrl)
  if not sUrl then return sUrl end
  local sHost = fExtractHost(sUrl)
  if not sHost then return sUrl end

  local sTarget = g_tHosts[sHost]
  if not sTarget then return sUrl end

  -- If target is 0.0.0.0 or 127.0.0.1, block
  if sTarget == "0.0.0.0" or sTarget == "127.0.0.1" then
    return nil, "Blocked by /etc/hosts: " .. sHost
  end

  local sNewUrl = sUrl:gsub(sHost, sTarget, 1)
  return sNewUrl
end

-- Rewrite a raw host (for TCP connect)
function oNF.RewriteTcpHost(sHost)
  if not sHost then return sHost end
  local sTarget = g_tHosts[sHost]
  if not sTarget then return sHost end
  if sTarget == "0.0.0.0" or sTarget == "127.0.0.1" then
    return nil, "Blocked by /etc/hosts: " .. sHost
  end
  return sTarget
end

-- =============================================
-- RULE MATCHING
-- =============================================

local function fMatchField(sRuleVal, sActual)
  if sRuleVal == "*" then return true end
  if type(sRuleVal) == "number" and type(sActual) == "number" then
    return sRuleVal == sActual
  end
  if type(sRuleVal) == "string" and type(sActual) == "string" then
    -- try exact match first
    if sRuleVal == sActual then return true end
    -- then Lua pattern match
    local bOk, bMatch = pcall(function()
      return sActual:match("^" .. sRuleVal .. "$") ~= nil
    end)
    return bOk and bMatch
  end
  return tostring(sRuleVal) == tostring(sActual)
end

-- Check if a connection is allowed.
-- Returns: "allow", "deny", or "log" (allow + audit)
-- Plus the matched rule for logging.
function oNF.CheckPolicy(sProto, sHost, nPort, nRing, nUid)
  if not g_bEnabled then return "allow", nil end

  for _, tRule in ipairs(g_tRules) do
    local bProtoMatch = fMatchField(tRule.proto or "*", sProto)
                     or fMatchField(tRule.proto or "*", "any")
    local bHostMatch  = fMatchField(tRule.host or "*", sHost or "")
    local bPortMatch  = fMatchField(tRule.port or "*", nPort or 0)
    local bRingMatch  = fMatchField(tRule.ring or "*", nRing or 3)

    -- UID matching (optional field)
    local bUidMatch = true
    if tRule.uid and tRule.uid ~= "*" then
      bUidMatch = fMatchField(tRule.uid, nUid or 1000)
    end

    if bProtoMatch and bHostMatch and bPortMatch and bRingMatch and bUidMatch then
      return tRule.action or "allow", tRule
    end
  end

  -- default allow if no rules matched
  return "allow", nil
end

-- =============================================
-- CONNECTION TRACKING
-- =============================================

function oNF.TrackConnect(nPid, nUid, sProto, sHost, nPort, nSessionId)
  if not g_tConnTracker[nPid] then
    g_tConnTracker[nPid] = {
      nUid   = nUid or 1000,
      nCount = 0,
      nBytes = 0,
      tConns = {},
    }
  end
  local tTracker = g_tConnTracker[nPid]
  tTracker.nCount = tTracker.nCount + 1
  tTracker.tConns[nSessionId] = {
    sProto   = sProto,
    sHost    = sHost,
    nPort    = nPort,
    nStart   = os.clock(),
    nBytes   = 0,
    sStatus  = "open",
  }
  return true
end

function oNF.TrackBytes(nPid, nSessionId, nBytes)
  local tTracker = g_tConnTracker[nPid]
  if not tTracker then return end
  tTracker.nBytes = tTracker.nBytes + nBytes
  local tConn = tTracker.tConns[nSessionId]
  if tConn then tConn.nBytes = tConn.nBytes + nBytes end
end

function oNF.TrackClose(nPid, nSessionId)
  local tTracker = g_tConnTracker[nPid]
  if not tTracker then return end
  local tConn = tTracker.tConns[nSessionId]
  if tConn then
    tConn.sStatus = "closed"
    tConn.nEnd = os.clock()
  end
  tTracker.nCount = math.max(0, tTracker.nCount - 1)
end

function oNF.GetProcessStats(nPid)
  return g_tConnTracker[nPid]
end

function oNF.GetAllStats()
  local tResult = {}
  for nPid, tT in pairs(g_tConnTracker) do
    table.insert(tResult, {
      nPid   = nPid,
      nUid   = tT.nUid,
      nActive = tT.nCount,
      nBytes = tT.nBytes,
    })
  end
  table.sort(tResult, function(a, b) return a.nPid < b.nPid end)
  return tResult
end

-- Check per-UID connection limit
function oNF.CheckConnectionLimit(nUid)
  local nTotal = 0
  for _, tT in pairs(g_tConnTracker) do
    if tT.nUid == nUid then
      nTotal = nTotal + tT.nCount
    end
  end
  return nTotal < g_nMaxSessionsPerUid, nTotal
end

function oNF.SetConnectionLimit(n)
  g_nMaxSessionsPerUid = n
end

-- =============================================
-- AUDIT LOG
-- =============================================

function oNF.Audit(sAction, sProto, sHost, nPort, nPid, nUid, sComment)
  table.insert(g_tAuditLog, {
    nTime    = os.clock(),
    sAction  = sAction,
    sProto   = sProto,
    sHost    = sHost or "?",
    nPort    = nPort or 0,
    nPid     = nPid or 0,
    nUid     = nUid or 0,
    sComment = sComment or "",
  })
  if #g_tAuditLog > g_nMaxAuditEntries then
    table.remove(g_tAuditLog, 1)
  end
end

function oNF.GetAuditLog()
  return g_tAuditLog
end

function oNF.ClearAuditLog()
  g_tAuditLog = {}
end

-- =============================================
-- DUMP (for debug)
-- =============================================

function oNF.DumpRules()
  return g_tRules
end

function oNF.DumpHosts()
  return g_tHosts
end

return oNF