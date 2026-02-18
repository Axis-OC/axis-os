--
-- /usr/commands/wget.lua
-- Download files from the web (v2 — uses http library)
--

local http = require("http")
local tArgs = env.ARGS

if not tArgs or #tArgs < 1 then
  print("Usage: wget <url> [output_path]")
  return
end

local sUrl = tArgs[1]
local sOutPath = tArgs[2]

if not sOutPath then
  -- infer filename from URL
  sOutPath = sUrl:match(".*/([^/]+)$") or "downloaded_file"
  -- strip query string
  sOutPath = sOutPath:match("^([^?]+)") or sOutPath
end
if sOutPath:sub(1, 1) ~= "/" then
  sOutPath = (env.PWD or "/") .. "/" .. sOutPath
  sOutPath = sOutPath:gsub("//", "/")
end

print("\27[36m::\27[37m Connecting to " .. sUrl .. "...")

local nSpinIdx = 1
local sSpinners = {"|", "/", "-", "\\"}

local tInfo, sErr = http.download(sUrl, sOutPath, function(nBytes)
  local sSizeStr = string.format("%.2f KB", nBytes / 1024)
  io.write("\r\27[K\27[32m" .. sSpinners[nSpinIdx] ..
           "\27[37m Received: " .. sSizeStr)
  nSpinIdx = nSpinIdx + 1
  if nSpinIdx > 4 then nSpinIdx = 1 end
end)

if tInfo then
  print(string.format("\n\27[32m[OK]\27[37m Saved to %s (%d bytes, HTTP %d, %dms connect)",
        sOutPath, tInfo.nBytes, tInfo.code, tInfo.connectMs))
else
  print("\n\27[31mError:\27[37m " .. tostring(sErr))
end