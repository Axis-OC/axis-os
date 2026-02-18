--
-- /lib/net.lua
-- AxisOS networking library: TCP sockets + ping
--
-- local net = require("net")
-- local result = net.ping("example.com")
-- local sock = net.connect("example.com", 80)
--

local fs = require("filesystem")
local oNet = {}

local function fOpenNet()
  local h = fs.open("/dev/net", "r")
  if not h then return nil, "Network device not available" end
  return h
end

-- =============================================
-- PING
-- =============================================

function oNet.ping(sHost, nPort, nCount, nTimeout)
  local hNet, sErr = fOpenNet()
  if not hNet then return nil, sErr end

  local bOk, tResult = fs.deviceControl(hNet, "ping", {
    sHost, nPort or 80, nCount or 4, nTimeout or 5
  })

  fs.close(hNet)

  if bOk and type(tResult) == "table" then
    return tResult
  else
    return nil, tostring(tResult or "Ping failed")
  end
end

-- =============================================
-- TCP SOCKETS
-- =============================================

function oNet.connect(sHost, nPort, nTimeout)
  local hNet, sErr = fOpenNet()
  if not hNet then return nil, sErr end

  local bOk, tResult = fs.deviceControl(hNet, "tcp_connect", {
    sHost, nPort, nTimeout or 10
  })

  if not bOk or type(tResult) ~= "table" then
    fs.close(hNet)
    return nil, tostring(tResult or "Connect failed")
  end

  local tSock = {
    _hNet     = hNet,
    _nSession = tResult.nSessionId,
    _bClosed  = false,
    connectMs = tResult.nConnectMs or 0,
  }

  function tSock:write(sData)
    if self._bClosed then return nil, "Socket closed" end
    local bWrOk, nWritten = fs.deviceControl(self._hNet, "tcp_write", {
      self._nSession, sData
    })
    return bWrOk and nWritten or nil, nWritten
  end

  function tSock:read(nCount)
    if self._bClosed then return nil end
    local bRdOk, sData = fs.deviceControl(self._hNet, "tcp_read", {
      self._nSession, nCount or math.huge
    })
    if bRdOk and sData and type(sData) == "string" and #sData > 0 then
      return sData
    end
    return nil
  end

  function tSock:close()
    if self._bClosed then return end
    self._bClosed = true
    fs.deviceControl(self._hNet, "tcp_close", {self._nSession})
    fs.close(self._hNet)
  end

  return tSock
end

-- =============================================
-- UTILITIES
-- =============================================

function oNet.info()
  local hNet = fOpenNet()
  if not hNet then return nil end
  local bOk, tInfo = fs.deviceControl(hNet, "info", {})
  fs.close(hNet)
  return bOk and tInfo or nil
end

function oNet.sessions()
  local hNet = fOpenNet()
  if not hNet then return nil end
  local bOk, tList = fs.deviceControl(hNet, "session_list", {})
  fs.close(hNet)
  return bOk and tList or {}
end

function oNet.cleanup()
  local hNet = fOpenNet()
  if not hNet then return 0 end
  local bOk, nCleaned = fs.deviceControl(hNet, "session_cleanup", {})
  fs.close(hNet)
  return bOk and nCleaned or 0
end

return oNet