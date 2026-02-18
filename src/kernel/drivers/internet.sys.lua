--
-- /drivers/internet.sys.lua
-- AxisOS Network Driver v2.1
-- Fixed timing: uses computer.uptime() instead of os.clock()
--

local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

g_tDriverInfo = {
  sDriverName = "AxisNet",
  sDriverType = tDKStructs.DRIVER_TYPE_KMD,
  nLoadPriority = 250,
  sVersion = "2.1.0",
}

local g_pDeviceObject = nil
local g_oNetProxy = nil
-- local g_oNetfilter = nil

-- =============================================
-- ROBUST TIME FUNCTION
-- computer.uptime() is wall time in OC.
-- Accessible through sandbox __index → _G chain.
-- =============================================

local function fNow()
  local bOk, nTime = pcall(function() return computer.uptime() end)
  if bOk and nTime then return nTime end
  -- fallback: raw_computer (Ring 0 only)
  bOk, nTime = pcall(function() return raw_computer.uptime() end)
  if bOk and nTime then return nTime end
  -- last resort
  return os.clock()
end

-- =============================================
-- SESSION MANAGEMENT
-- =============================================

local g_tSessions = {}
local g_nNextSession = 1
local MAX_SESSIONS = 32
local DEFAULT_TIMEOUT = 10
local MAX_WAIT_YIELDS = 500

local function fAllocSession(sType)
  if g_nNextSession > 99999 then g_nNextSession = 1 end
  local nId = g_nNextSession
  g_nNextSession = g_nNextSession + 1
  g_tSessions[nId] = {
    nId           = nId,
    sType         = sType,
    oHandle       = nil,
    sStatus       = "new",
    sError        = nil,
    nHttpCode     = nil,
    sHttpMsg      = nil,
    tHttpHeaders  = nil,
    sUrl          = nil,
    sMethod       = nil,
    nStartTime    = fNow(),
    nConnectTime  = nil,
    nBytesRead    = 0,
    nBytesWritten = 0,
  }
  return nId, g_tSessions[nId]
end

local function fCloseSession(nId)
  local s = g_tSessions[nId]
  if not s then return false end
  if s.oHandle then pcall(s.oHandle.close) end
  s.oHandle = nil
  s.sStatus = "closed"
  return true
end

local function fDestroySession(nId)
  fCloseSession(nId)
  g_tSessions[nId] = nil
end

local function fCountSessions()
  local n = 0
  for _ in pairs(g_tSessions) do n = n + 1 end
  return n
end

local function fCleanupStale()
  local nCleaned = 0
  for nId, s in pairs(g_tSessions) do
    if s.sStatus == "closed" or s.sStatus == "error" then
      g_tSessions[nId] = nil
      nCleaned = nCleaned + 1
    elseif s.sStatus ~= "new" and (fNow() - s.nStartTime) > 120 then
      fCloseSession(nId)
      g_tSessions[nId] = nil
      nCleaned = nCleaned + 1
    end
  end
  return nCleaned
end

-- =============================================
-- CONNECTION WAIT (fixed timing)
-- =============================================

local function fWaitConnect(oHandle, nTimeout)
  local nDeadline = fNow() + (nTimeout or DEFAULT_TIMEOUT)
  local nYields = 0

  while nYields < MAX_WAIT_YIELDS do
    -- check wall-clock deadline
    if fNow() >= nDeadline then
      return nil, "Connection timed out"
    end

    -- probe connection status (safely)
    local bPcallOk, r1, r2 = pcall(oHandle.finishConnect)

    if not bPcallOk then
      -- finishConnect threw an error
      return nil, tostring(r1)
    end

    if r1 == true then
      -- connected!
      return true
    end

    if r1 == nil and r2 then
      -- connection error (nil, "reason")
      return nil, tostring(r2)
    end

    -- r1 == false or (r1 == nil, r2 == nil): still connecting
    nYields = nYields + 1
    syscall("process_yield")
  end

  return nil, "Connection timed out (yield limit)"
end

local function fLoadNetfilter()
  local bOk, oNF = pcall(require, "netfilter")
  if not bOk or not oNF then
    oKMD.DkPrint("AxisNet: netfilter not available (no policy enforcement)")
    return nil
  end

  local bRulesOk, sRulesData = syscall("vfs_read_file", "/etc/netpolicy.lua")
  if bRulesOk and sRulesData then
    oNF.LoadRules(sRulesData)
    oKMD.DkPrint("AxisNet: Loaded /etc/netpolicy.lua")
  else
    oKMD.DkPrint("AxisNet: No /etc/netpolicy.lua (default: allow all)")
  end

  local bHostsOk, sHostsData = syscall("vfs_read_file", "/etc/hosts")
  if bHostsOk and sHostsData then
    oNF.LoadHosts(sHostsData)
    oKMD.DkPrint("AxisNet: Loaded /etc/hosts")
  end

  return oNF
end

local function fGetCallerInfo(pIrp)
  local nPid = pIrp.nSenderPid or 0
  local nRing = (nPid < 20) and 1 or 3
  local nUid = (nPid < 20) and 0 or 1000
  return nPid, nRing, nUid
end

local function fCheckAndAudit(pIrp, sProto, sHost, nPort)
  if not g_oNetfilter then return true end

  local nPid, nRing, nUid = fGetCallerInfo(pIrp)

  local bUnderLimit, nCurrent = g_oNetfilter.CheckConnectionLimit(nUid)
  if not bUnderLimit then
    g_oNetfilter.Audit("DENY_LIMIT", sProto, sHost, nPort, nPid, nUid,
                       "Connection limit (" .. nCurrent .. ")")
    return false, "Connection limit reached for UID " .. nUid
  end

  local sAction, tRule = g_oNetfilter.CheckPolicy(sProto, sHost, nPort, nRing, nUid)

  if sAction == "deny" then
    local sComment = tRule and tRule.comment or "Policy denied"
    g_oNetfilter.Audit("DENY", sProto, sHost, nPort, nPid, nUid, sComment)
    oKMD.DkPrint("AxisNet: BLOCKED " .. sProto .. " " ..
                 tostring(sHost) .. ":" .. tostring(nPort) ..
                 " PID " .. nPid .. " (" .. sComment .. ")")
    return false, "Blocked by network policy: " .. sComment
  end

  if sAction == "log" then
    g_oNetfilter.Audit("LOG_ALLOW", sProto, sHost, nPort, nPid, nUid,
                       tRule and tRule.comment or "")
  end

  g_oNetfilter.Audit("ALLOW", sProto, sHost, nPort, nPid, nUid, "")
  return true
end

-- =============================================
-- DEVICE_CONTROL METHODS
-- =============================================

local tMethods = {}

function tMethods.info(pDev, pIrp, tArgs)
  local bHttp, bTcp = false, false
  if g_oNetProxy then
    pcall(function() bHttp = g_oNetProxy.isHttpEnabled() end)
    pcall(function() bTcp = g_oNetProxy.isTcpEnabled() end)
  end
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, {
    bHttpEnabled    = bHttp,
    bTcpEnabled     = bTcp,
    bOnline         = g_oNetProxy ~= nil,
    nMaxSessions    = MAX_SESSIONS,
    nActiveSessions = fCountSessions(),
    sDriverVersion  = "2.1.0",
  })
end

function tMethods.http_request(pDev, pIrp, tArgs)
  local sUrl     = tArgs[1]
  local sMethod  = (tArgs[2] or "GET"):upper()
  local sBody    = tArgs[3]
  local tHeaders = tArgs[4]
  local nTimeout = tArgs[5] or DEFAULT_TIMEOUT

  if not sUrl or #sUrl == 0 then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER, "Missing URL")
    return
  end
  -- HOST REWRITING
  if g_oNetfilter then
    local sRewritten, sBlockErr = g_oNetfilter.RewriteHost(sUrl)
    if not sRewritten then
      oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_ACCESS_DENIED, sBlockErr)
      return
    end
    if sRewritten ~= sUrl then
      oKMD.DkPrint("AxisNet: Rewrote " .. sUrl .. " -> " .. sRewritten)
      sUrl = sRewritten
    end
  end

  -- POLICY CHECK
  local sHost = sUrl:match("^https?://([^/:]+)") or sUrl:match("^([^/:]+)")
  local nPort = tonumber(sUrl:match("^https?://[^/:]+:(%d+)")) or
                (sUrl:sub(1, 5) == "https" and 443 or 80)
  local bAllowed, sDenyReason = fCheckAndAudit(pIrp, "http", sHost, nPort)
  if not bAllowed then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_ACCESS_DENIED, sDenyReason)
    return
  end

  if not g_oNetProxy then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_DEVICE_NOT_READY, "No internet card")
    return
  end
  if fCountSessions() >= MAX_SESSIONS then
    fCleanupStale()
    if fCountSessions() >= MAX_SESSIONS then
      oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_DEVICE_BUSY, "Too many sessions")
      return
    end
  end

  local nId, tSess = fAllocSession("http")
  tSess.sUrl = sUrl
  tSess.sMethod = sMethod

  local vPostData = nil
  if sMethod == "POST" or sMethod == "PUT" or sMethod == "PATCH" then
    vPostData = sBody or ""
  end

  local bOk, oHandle = pcall(g_oNetProxy.request, sUrl, vPostData, tHeaders)
  if not bOk or not oHandle then
    tSess.sStatus = "error"
    tSess.sError = tostring(oHandle or "Request creation failed")
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_UNSUCCESSFUL, tSess.sError)
    fDestroySession(nId)
    return
  end

  tSess.oHandle = oHandle
  tSess.sStatus = "connecting"

  local bConn, sErr = fWaitConnect(oHandle, nTimeout)
  if not bConn then
    tSess.sStatus = "error"
    tSess.sError = sErr
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_UNSUCCESSFUL, sErr)
    fDestroySession(nId)
    return
  end

  tSess.nConnectTime = fNow()
  tSess.sStatus = "connected"
  -- TRACK CONNECTION
  if g_oNetfilter then
    local nPid = pIrp.nSenderPid or 0
    local nUid = (nPid < 20) and 0 or 1000
    g_oNetfilter.TrackConnect(nPid, nUid, "http", sHost, nPort, nId)
  end

  -- fetch response metadata
  local bResOk, nCode, sMsg, tHdrs = pcall(oHandle.response)
  if bResOk then
    tSess.nHttpCode = nCode
    tSess.sHttpMsg = sMsg
    tSess.tHttpHeaders = tHdrs
  end

  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, {
    nSessionId     = nId,
    nStatusCode    = tSess.nHttpCode or 0,
    sStatusMessage = tSess.sHttpMsg or "",
    tHeaders       = tSess.tHttpHeaders or {},
    nConnectMs     = math.floor((tSess.nConnectTime - tSess.nStartTime) * 1000),
  })
end

function tMethods.http_read(pDev, pIrp, tArgs)
  local nId    = tArgs[1]
  local nCount = tArgs[2] or math.huge
  local tSess  = g_tSessions[nId]

  if not tSess or tSess.sType ~= "http" then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER, "Invalid session")
    return
  end
  if not tSess.oHandle or tSess.sStatus == "closed" then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_END_OF_FILE)
    return
  end

  local bOk, sData = pcall(tSess.oHandle.read, nCount)
  if bOk and sData then
    tSess.nBytesRead = tSess.nBytesRead + #sData
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, sData)
  else
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_END_OF_FILE)
  end
  if g_oNetfilter and bOk and sData then
    g_oNetfilter.TrackBytes(pIrp.nSenderPid or 0, nId, #sData)
  end
  
end

function tMethods.http_close(pDev, pIrp, tArgs)
  local nId = tArgs[1]
  if fCloseSession(nId) then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
  else
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER, "Unknown session")
  end
  if g_oNetfilter then
    g_oNetfilter.TrackClose(pIrp.nSenderPid or 0, nId)
  end
end

function tMethods.tcp_connect(pDev, pIrp, tArgs)
  local sHost    = tArgs[1]
  local nPort    = tonumber(tArgs[2])
  local nTimeout = tArgs[3] or DEFAULT_TIMEOUT

  if not sHost or not nPort then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER, "Missing host or port")
    return
  end
  if not g_oNetProxy then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_DEVICE_NOT_READY, "No internet card")
    return
  end
  if fCountSessions() >= MAX_SESSIONS then fCleanupStale() end

  local nId, tSess = fAllocSession("tcp")

  local bOk, oHandle = pcall(g_oNetProxy.connect, sHost, nPort)
  if not bOk or not oHandle then
    tSess.sStatus = "error"
    tSess.sError = tostring(oHandle or "Connect call failed")
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_UNSUCCESSFUL, tSess.sError)
    fDestroySession(nId)
    return
  end
  

  tSess.oHandle = oHandle
  tSess.sStatus = "connecting"

  -- HOST REWRITING
  if g_oNetfilter then
    local sRewritten, sBlockErr = g_oNetfilter.RewriteTcpHost(sHost)
    if not sRewritten then
      oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_ACCESS_DENIED, sBlockErr)
      return
    end
    sHost = sRewritten
  end

  -- POLICY CHECK
  local bAllowed, sDenyReason = fCheckAndAudit(pIrp, "tcp", sHost, nPort)
  if not bAllowed then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_ACCESS_DENIED, sDenyReason)
    return
  end

  local bConn, sErr = fWaitConnect(oHandle, nTimeout)
  if not bConn then
    tSess.sStatus = "error"
    tSess.sError = sErr
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_UNSUCCESSFUL, sErr)
    fDestroySession(nId)
    return
  end

  tSess.nConnectTime = fNow()
  tSess.sStatus = "connected"

  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, {
    nSessionId = nId,
    nConnectMs = math.floor((tSess.nConnectTime - tSess.nStartTime) * 1000),
  })
end

function tMethods.tcp_write(pDev, pIrp, tArgs)
  local nId   = tArgs[1]
  local sData = tArgs[2]
  local tSess = g_tSessions[nId]

  if not tSess or tSess.sType ~= "tcp" or not tSess.oHandle then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER, "Invalid session")
    return
  end

  local bOk, nWritten = pcall(tSess.oHandle.write, sData)
  if bOk then
    tSess.nBytesWritten = tSess.nBytesWritten + (nWritten or #sData)
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, nWritten or #sData)
  else
    tSess.sStatus = "error"
    tSess.sError = tostring(nWritten)
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_UNSUCCESSFUL, tSess.sError)
  end
end

function tMethods.tcp_read(pDev, pIrp, tArgs)
  local nId    = tArgs[1]
  local nCount = tArgs[2] or math.huge
  local tSess  = g_tSessions[nId]

  if not tSess or tSess.sType ~= "tcp" or not tSess.oHandle then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER, "Invalid session")
    return
  end

  local bOk, sData = pcall(tSess.oHandle.read, nCount)
  if bOk and sData then
    tSess.nBytesRead = tSess.nBytesRead + #sData
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, sData)
  else
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_END_OF_FILE)
  end
end

function tMethods.tcp_close(pDev, pIrp, tArgs)
  tMethods.http_close(pDev, pIrp, tArgs)
  if g_oNetfilter then
    g_oNetfilter.TrackClose(pIrp.nSenderPid or 0, nId)
  end
end

function tMethods.ping(pDev, pIrp, tArgs)
  local sHost    = tArgs[1]
  local nPort    = tonumber(tArgs[2]) or 80
  local nCount   = tonumber(tArgs[3]) or 4
  local nTimeout = tonumber(tArgs[4]) or 5

  if not sHost then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER, "Missing host")
    return
  end

  -- POLICY CHECK
  local bAllowed, sDenyReason = fCheckAndAudit(pIrp, "tcp", sHost, nPort)
  if not bAllowed then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_ACCESS_DENIED, sDenyReason)
    return
  end

  if not g_oNetProxy then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_DEVICE_NOT_READY, "No internet card")
    return
  end
  if nCount > 20 then nCount = 20 end

  -- check TCP capability first
  local bTcpOk = false
  pcall(function() bTcpOk = g_oNetProxy.isTcpEnabled() end)

  if not bTcpOk then
    -- fallback: HTTP-based ping
    oKMD.DkPrint("AxisNet: TCP not enabled, using HTTP ping")
    local tResults = {}
    local nSuccess = 0
    local nTotalMs = 0
    local nMinMs = 999999
    local nMaxMs = 0

    for i = 1, nCount do
      local nStart = fNow()
      local sTestUrl = "http://" .. sHost .. ":" .. nPort .. "/"
      local bReqOk, oHandle = pcall(g_oNetProxy.request, sTestUrl)

      if not bReqOk or not oHandle then
        table.insert(tResults, { nSeq = i, sStatus = "error",
                                 sError = tostring(oHandle or "request failed") })
      else
        local bConn, sErr = fWaitConnect(oHandle, nTimeout)
        local nElapsed = math.floor((fNow() - nStart) * 1000)
        pcall(oHandle.close)

        if bConn then
          table.insert(tResults, { nSeq = i, sStatus = "ok", nMs = nElapsed })
          nSuccess = nSuccess + 1
          nTotalMs = nTotalMs + nElapsed
          if nElapsed < nMinMs then nMinMs = nElapsed end
          if nElapsed > nMaxMs then nMaxMs = nElapsed end
        else
          table.insert(tResults, { nSeq = i, sStatus = "timeout",
                                   nMs = nElapsed, sError = sErr })
        end
      end
      if i < nCount then syscall("process_yield") end
    end

    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, {
      sHost    = sHost,
      nPort    = nPort,
      sMethod  = "http",
      nSent    = nCount,
      nRecv    = nSuccess,
      nLoss    = math.floor(((nCount - nSuccess) / math.max(nCount, 1)) * 100),
      nMinMs   = nMinMs < 999999 and nMinMs or 0,
      nAvgMs   = nSuccess > 0 and math.floor(nTotalMs / nSuccess) or 0,
      nMaxMs   = nMaxMs,
      tResults = tResults,
    })
    return
  end

  -- TCP-based ping
  local tResults = {}
  local nSuccess = 0
  local nTotalMs = 0
  local nMinMs = 999999
  local nMaxMs = 0

  for i = 1, nCount do
    local nStart = fNow()
    local bOk, oHandle = pcall(g_oNetProxy.connect, sHost, nPort)

    if not bOk or not oHandle then
      table.insert(tResults, { nSeq = i, sStatus = "error",
                               sError = tostring(oHandle or "connect failed") })
    else
      local bConn, sErr = fWaitConnect(oHandle, nTimeout)
      local nElapsed = math.floor((fNow() - nStart) * 1000)

      if bConn then
        pcall(oHandle.close)
        table.insert(tResults, { nSeq = i, sStatus = "ok", nMs = nElapsed })
        nSuccess = nSuccess + 1
        nTotalMs = nTotalMs + nElapsed
        if nElapsed < nMinMs then nMinMs = nElapsed end
        if nElapsed > nMaxMs then nMaxMs = nElapsed end
      else
        pcall(oHandle.close)
        table.insert(tResults, { nSeq = i, sStatus = "timeout",
                                 nMs = nElapsed, sError = sErr })
      end
    end

    -- yield between probes
    if i < nCount then syscall("process_yield") end
  end

  local nAvgMs = nSuccess > 0 and math.floor(nTotalMs / nSuccess) or 0
  local nLoss = math.floor(((nCount - nSuccess) / math.max(nCount, 1)) * 100)

  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, {
    sHost    = sHost,
    nPort    = nPort,
    sMethod  = "tcp",
    nSent    = nCount,
    nRecv    = nSuccess,
    nLoss    = nLoss,
    nMinMs   = nMinMs < 999999 and nMinMs or 0,
    nAvgMs   = nAvgMs,
    nMaxMs   = nMaxMs,
    tResults = tResults,
  })
end

function tMethods.session_list(pDev, pIrp, tArgs)
  local tList = {}
  for nId, s in pairs(g_tSessions) do
    table.insert(tList, {
      nId     = nId,
      sType   = s.sType,
      sStatus = s.sStatus,
      sUrl    = s.sUrl,
      nBytes  = s.nBytesRead + s.nBytesWritten,
      nAge    = math.floor((fNow() - s.nStartTime) * 1000),
    })
  end
  table.sort(tList, function(a, b) return a.nId < b.nId end)
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, tList)
end

function tMethods.session_cleanup(pDev, pIrp, tArgs)
  local n = fCleanupStale()
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, n)
end

function tMethods.nf_reload(pDev, pIrp, tArgs)
  if not g_oNetfilter then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_NOT_IMPLEMENTED, "No netfilter")
    return
  end
  local bRulesOk, sRules = syscall("vfs_read_file", "/etc/netpolicy.lua")
  if bRulesOk and sRules then g_oNetfilter.LoadRules(sRules) end
  local bHostsOk, sHosts = syscall("vfs_read_file", "/etc/hosts")
  if bHostsOk and sHosts then g_oNetfilter.LoadHosts(sHosts) end
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, "Reloaded")
end

function tMethods.nf_audit(pDev, pIrp, tArgs)
  if not g_oNetfilter then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, {})
    return
  end
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, g_oNetfilter.GetAuditLog())
end

function tMethods.nf_audit_clear(pDev, pIrp, tArgs)
  if g_oNetfilter then g_oNetfilter.ClearAuditLog() end
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

function tMethods.nf_stats(pDev, pIrp, tArgs)
  if not g_oNetfilter then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, {})
    return
  end
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, g_oNetfilter.GetAllStats())
end

function tMethods.nf_rules(pDev, pIrp, tArgs)
  if not g_oNetfilter then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, {})
    return
  end
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, g_oNetfilter.DumpRules())
end

function tMethods.nf_hosts(pDev, pIrp, tArgs)
  if not g_oNetfilter then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, {})
    return
  end
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, g_oNetfilter.DumpHosts())
end

function tMethods.nf_enable(pDev, pIrp, tArgs)
  if not g_oNetfilter then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_NOT_IMPLEMENTED)
    return
  end
  g_oNetfilter.SetEnabled(tArgs[1] ~= false)
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, g_oNetfilter.IsEnabled())
end

function tMethods.nf_set_limit(pDev, pIrp, tArgs)
  if not g_oNetfilter then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_NOT_IMPLEMENTED)
    return
  end
  local n = tonumber(tArgs[1])
  if n and n > 0 then
    g_oNetfilter.SetConnectionLimit(n)
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, n)
  else
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER)
  end
end

-- =============================================
-- IRP HANDLERS
-- =============================================

local function fCreate(pDev, pIrp)
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

local function fClose(pDev, pIrp)
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

-- Legacy write: URL as data → GET request
local g_tLegacySessions = {}

local function fWrite(pDev, pIrp)
  local sUrl = pIrp.tParameters.sData
  if not sUrl or not g_oNetProxy then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER)
    return
  end
  sUrl = sUrl:gsub("\n", "")

  local nOldId = g_tLegacySessions[pIrp.nSenderPid]
  if nOldId then fDestroySession(nOldId) end

  local nId, tSess = fAllocSession("http")
  tSess.sUrl = sUrl
  tSess.sMethod = "GET"

  local bOk, oHandle = pcall(g_oNetProxy.request, sUrl)
  if not bOk or not oHandle then
    fDestroySession(nId)
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_UNSUCCESSFUL, "Request failed")
    return
  end

  tSess.oHandle = oHandle
  tSess.sStatus = "connecting"

  local bConn, sErr = fWaitConnect(oHandle, DEFAULT_TIMEOUT)
  if not bConn then
    fDestroySession(nId)
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_UNSUCCESSFUL, sErr)
    return
  end

  tSess.nConnectTime = fNow()
  tSess.sStatus = "connected"
  g_tLegacySessions[pIrp.nSenderPid] = nId

  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, #sUrl)
end

local function fRead(pDev, pIrp)
  local nId = g_tLegacySessions[pIrp.nSenderPid]
  local tSess = nId and g_tSessions[nId]
  if not tSess or not tSess.oHandle then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_END_OF_FILE)
    return
  end
  local bOk, sData = pcall(tSess.oHandle.read, math.huge)
  if bOk and sData then
    tSess.nBytesRead = tSess.nBytesRead + #sData
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, sData)
  else
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_END_OF_FILE)
  end
end

local function fDeviceControl(pDev, pIrp)
  local sMethod = pIrp.tParameters.sMethod
  local tArgs   = pIrp.tParameters.tArgs or {}
  local fMethod = tMethods[sMethod]

  if fMethod then
    local bOk, sErr = pcall(fMethod, pDev, pIrp, tArgs)
    if not bOk then
      oKMD.DkPrint("AxisNet: Method '" .. tostring(sMethod) .. "' crashed: " .. tostring(sErr))
      -- try to complete the IRP if it wasn't already
      pcall(oKMD.DkCompleteRequest, pIrp, tStatus.STATUS_UNSUCCESSFUL,
            "Internal error: " .. tostring(sErr))
    end
  else
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_NOT_IMPLEMENTED,
                           "Unknown method: " .. tostring(sMethod))
  end
end

-- =============================================
-- DRIVER ENTRY
-- =============================================

function DriverEntry(pDriverObject)
  oKMD.DkPrint("AxisNet v2.1: Initializing...")

  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CREATE]         = fCreate
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CLOSE]          = fClose
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_WRITE]          = fWrite
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_READ]           = fRead
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_DEVICE_CONTROL] = fDeviceControl

  local nSt, pDevObj = oKMD.DkCreateDevice(pDriverObject, "\\Device\\Net0")
  if nSt ~= tStatus.STATUS_SUCCESS then return nSt end
  g_pDeviceObject = pDevObj

  local bOk, tList = syscall("raw_component_list", "internet")
  if bOk and tList then
    for sAddr in pairs(tList) do
      local _, p = oKMD.DkGetHardwareProxy(sAddr)
      g_oNetProxy = p
      break
    end
  end

  if not g_oNetProxy then
    oKMD.DkPrint("AxisNet: No internet card found.")
  else
    local bHttp, bTcp = false, false
    pcall(function() bHttp = g_oNetProxy.isHttpEnabled() end)
    pcall(function() bTcp = g_oNetProxy.isTcpEnabled() end)
    oKMD.DkPrint("AxisNet: Card found. HTTP=" .. tostring(bHttp) .. " TCP=" .. tostring(bTcp))
    oKMD.DkPrint("AxisNet: Time source check: fNow()=" .. tostring(fNow()))
  end

  oKMD.DkCreateSymbolicLink("/dev/net", "\\Device\\Net0")

  pcall(function()
    syscall("reg_create_key", "@VT\\DRV\\AxisNet")
    syscall("reg_set_value", "@VT\\DRV\\AxisNet", "Version", "2.1.0", "STR")
    syscall("reg_set_value", "@VT\\DRV\\AxisNet", "Online", g_oNetProxy ~= nil, "BOOL")
  end)

  oKMD.DkPrint("AxisNet v2.1: Online at /dev/net")
  return tStatus.STATUS_SUCCESS
end

function DriverUnload(pDriverObject)
  for nId in pairs(g_tSessions) do fDestroySession(nId) end
  oKMD.DkDeleteSymbolicLink("/dev/net")
  oKMD.DkDeleteDevice(g_pDeviceObject)
  return tStatus.STATUS_SUCCESS
end

-- =============================================
-- MAIN LOOP
-- =============================================

while true do
  local bOk, nSenderPid, sSignalName, p1, p2 = syscall("signal_pull")
  if bOk then
    if sSignalName == "driver_init" then
      local pDriverObject = p1
      pDriverObject.fDriverUnload = DriverUnload
      local nSt = DriverEntry(pDriverObject)
      syscall("signal_send", nSenderPid, "driver_init_complete", nSt, pDriverObject)
    elseif sSignalName == "irp_dispatch" then
      local pIrp = p1
      local fHandler = p2
      fHandler(g_pDeviceObject, pIrp)
    end
  end
end