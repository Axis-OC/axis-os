--
-- /usr/commands/curl.lua
-- HTTP client tool
--
-- Usage:
--   curl <url>                     GET request
--   curl -X POST -d 'data' <url>  POST with body
--   curl -H "Key: Val" <url>      Custom header
--   curl -v <url>                 Verbose (show headers)
--   curl -o file.txt <url>        Save to file
--   curl -s <url>                 Silent (body only)
--   curl -I <url>                 Headers only (HEAD)
--

local http = require("http")
local fs   = require("filesystem")
local tArgs = env.ARGS or {}

local C = {
  R = "\27[37m", GRN = "\27[32m", RED = "\27[31m",
  YLW = "\27[33m", CYN = "\27[36m", GRY = "\27[90m", MAG = "\27[35m",
}

-- parse args
local sUrl      = nil
local sMethod   = "GET"
local sBody     = nil
local tHeaders  = {}
local sOutFile  = nil
local bVerbose  = false
local bSilent   = false
local bHeadOnly = false

local i = 1
while i <= #tArgs do
  local a = tArgs[i]
  if a == "-X" then
    i = i + 1; sMethod = (tArgs[i] or "GET"):upper()
  elseif a == "-d" or a == "--data" then
    i = i + 1; sBody = tArgs[i]
    if sMethod == "GET" then sMethod = "POST" end
  elseif a == "-H" or a == "--header" then
    i = i + 1
    local sHdr = tArgs[i]
    if sHdr then
      local nColon = sHdr:find(":")
      if nColon then
        local k = sHdr:sub(1, nColon - 1)
        local v = sHdr:sub(nColon + 1):match("^%s*(.-)%s*$")
        tHeaders[k] = v
      end
    end
  elseif a == "-o" then
    i = i + 1; sOutFile = tArgs[i]
  elseif a == "-v" or a == "--verbose" then
    bVerbose = true
  elseif a == "-s" or a == "--silent" then
    bSilent = true
  elseif a == "-I" or a == "--head" then
    bHeadOnly = true; sMethod = "HEAD"
  elseif a == "-h" or a == "--help" then
    print(C.CYN .. "curl" .. C.R .. " - HTTP client")
    print("Usage: curl [opts] <url>")
    print("  -X METHOD   HTTP method (GET, POST, PUT)")
    print("  -d DATA     Request body")
    print("  -H HDR      Header (\"Key: Value\")")
    print("  -o FILE     Save body to file")
    print("  -v          Verbose (show request/response headers)")
    print("  -s          Silent (body only, no status)")
    print("  -I          HEAD request (headers only)")
    return
  elseif a:sub(1, 1) ~= "-" then
    sUrl = a
  end
  i = i + 1
end

if not sUrl then
  print("Usage: curl <url>")
  return
end

-- resolve output path
if sOutFile and sOutFile:sub(1, 1) ~= "/" then
  sOutFile = (env.PWD or "/") .. "/" .. sOutFile
  sOutFile = sOutFile:gsub("//", "/")
end

-- verbose: show request
if bVerbose then
  print(C.CYN .. "> " .. C.R .. sMethod .. " " .. sUrl)
  for k, v in pairs(tHeaders) do
    print(C.CYN .. "> " .. C.R .. k .. ": " .. v)
  end
  if sBody then print(C.CYN .. "> " .. C.GRY .. "[body: " .. #sBody .. " bytes]" .. C.R) end
  print("")
end

-- make request
local tHdrs = next(tHeaders) and tHeaders or nil
local stream, sErr = http.open(sUrl, sMethod, sBody, tHdrs)

if not stream then
  if not bSilent then
    print(C.RED .. "Error: " .. C.R .. tostring(sErr))
  end
  return
end

-- show response headers
if not bSilent then
  local sCodeColor = C.GRN
  if stream.code >= 400 then sCodeColor = C.RED
  elseif stream.code >= 300 then sCodeColor = C.YLW end

  if bVerbose or bHeadOnly then
    print(string.format("%s< %sHTTP %d %s%s  (%d ms)",
          C.MAG, sCodeColor, stream.code, stream.message, C.R, stream.connectMs))
    if stream.headers then
      for k, v in pairs(stream.headers) do
        print(C.MAG .. "< " .. C.R .. tostring(k) .. ": " .. tostring(v))
      end
    end
    print("")
  else
    io.write(string.format("%sHTTP %d%s (%d ms) ",
             sCodeColor, stream.code, C.R, stream.connectMs))
  end
end

-- read body
if not bHeadOnly then
  local hOut = nil
  if sOutFile then
    hOut = fs.open(sOutFile, "w")
    if not hOut then
      print(C.RED .. "Cannot open: " .. C.R .. sOutFile)
      stream:close()
      return
    end
  end

  local nTotal = 0
  while true do
    local sChunk = stream:read(2048)
    if not sChunk then break end
    nTotal = nTotal + #sChunk
    if hOut then
      fs.write(hOut, sChunk)
      if not bSilent then
        io.write(string.format("\r%s%d bytes%s downloaded",
                 C.GRY, nTotal, C.R))
      end
    else
      io.write(sChunk)
    end
  end

  if hOut then
    fs.close(hOut)
    if not bSilent then
      print(string.format("\n%sSaved to %s%s (%d bytes)",
            C.GRN, sOutFile, C.R, nTotal))
    end
  elseif not bSilent and not bVerbose then
    -- newline after body if it didn't end with one
    print("")
  end
end

stream:close()