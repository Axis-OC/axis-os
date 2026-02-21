--
-- /lib/http.lua
-- AxisOS HTTP client library
--
-- local http = require("http")
-- local resp = http.get("https://example.com")
-- print(resp.code, resp.body)
--

local fs = require("filesystem")
local oHttp = {}

local function fOpenNet()
  local h = fs.open("/dev/net", "r")
  if not h then return nil, "Network device not available (/dev/net)" end
  return h
end

-- =============================================
-- STREAMING API
-- =============================================

-- Open an HTTP stream (for large responses)
-- Returns a stream object or nil + error
function oHttp.open(sUrl, sMethod, sBody, tHeaders, nTimeout)
  local hNet, sErr = fOpenNet()
  if not hNet then return nil, sErr end

  local bOk, tResult = fs.deviceControl(hNet, "http_request", {
    sUrl, sMethod or "GET", sBody, tHeaders, nTimeout or 10
  })

  if not bOk then
    fs.close(hNet)
    return nil, tostring(tResult or "Request failed")
  end

  if type(tResult) ~= "table" then
    fs.close(hNet)
    return nil, "Unexpected response from driver"
  end

  local tStream = {
    _hNet      = hNet,
    _nSession  = tResult.nSessionId,
    _bClosed   = false,
    code       = tResult.nStatusCode or 0,
    message    = tResult.sStatusMessage or "",
    headers    = tResult.tHeaders or {},
    connectMs  = tResult.nConnectMs or 0,
  }

  function tStream:read(nCount)
      if self._bClosed then return nil end
      -- Retry nil reads: chunked responses via reverse proxies
      -- (Cloudflare, nginx) have gaps between TCP segments.
      -- Each yield ≈ 50ms (one OC tick), 8 retries ≈ 400ms max wait.
      local nRetries = 0
      while nRetries < 8 do
          local bReadOk, sData = fs.deviceControl(self._hNet, "http_read", {
              self._nSession, nCount or math.huge
          })
          if bReadOk and sData and type(sData) == "string" and #sData > 0 then
              return sData
          end
          nRetries = nRetries + 1
          pcall(function() syscall("process_yield") end)
      end
      return nil  -- true EOF after retries exhausted
  end

  function tStream:close()
    if self._bClosed then return end
    self._bClosed = true
    fs.deviceControl(self._hNet, "http_close", {self._nSession})
    fs.close(self._hNet)
  end

  return tStream
end

-- =============================================
-- SIMPLE API (reads entire response)
-- =============================================

local function fFullRequest(sUrl, sMethod, sBody, tHeaders, nTimeout)
  local stream, sErr = oHttp.open(sUrl, sMethod, sBody, tHeaders, nTimeout)
  if not stream then
    return { code = 0, body = "", headers = {}, error = sErr }
  end

  local tChunks = {}
  local nNilReads = 0
  while nNilReads < 4 do
    local sChunk = stream:read(4096)
    if sChunk then
      table.insert(tChunks, sChunk)
      nNilReads = 0
    else
      nNilReads = nNilReads + 1
    end
  end

  local tResp = {
    code      = stream.code,
    message   = stream.message,
    headers   = stream.headers,
    body      = table.concat(tChunks),
    connectMs = stream.connectMs,
    error     = nil,
  }

  stream:close()
  return tResp
end

function oHttp.get(sUrl, tHeaders, nTimeout)
  return fFullRequest(sUrl, "GET", nil, tHeaders, nTimeout)
end

function oHttp.post(sUrl, sBody, tHeaders, nTimeout)
  return fFullRequest(sUrl, "POST", sBody, tHeaders, nTimeout)
end

function oHttp.put(sUrl, sBody, tHeaders, nTimeout)
  return fFullRequest(sUrl, "PUT", sBody, tHeaders, nTimeout)
end

function oHttp.head(sUrl, tHeaders, nTimeout)
  return fFullRequest(sUrl, "HEAD", nil, tHeaders, nTimeout)
end

function oHttp.request(sMethod, sUrl, sBody, tHeaders, nTimeout)
  return fFullRequest(sUrl, sMethod, sBody, tHeaders, nTimeout)
end

-- =============================================
-- UTILITY
-- =============================================

function oHttp.info()
  local hNet = fOpenNet()
  if not hNet then return nil, "No network" end
  local bOk, tInfo = fs.deviceControl(hNet, "info", {})
  fs.close(hNet)
  return bOk and tInfo or nil
end

function oHttp.download(sUrl, sDestPath, fProgress)
  local stream, sErr = oHttp.open(sUrl)
  if not stream then return nil, sErr end

  local hFile = fs.open(sDestPath, "w")
  if not hFile then
    stream:close()
    return nil, "Cannot open " .. sDestPath .. " for writing"
  end

  local nTotal = 0
  while true do
    local sChunk = stream:read(2048)
    if not sChunk then break end
    fs.write(hFile, sChunk)
    nTotal = nTotal + #sChunk
    if fProgress then fProgress(nTotal) end
  end

  fs.close(hFile)
  local tInfo = { code = stream.code, nBytes = nTotal, connectMs = stream.connectMs }
  stream:close()
  return tInfo
end

return oHttp