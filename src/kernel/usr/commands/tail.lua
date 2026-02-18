-- tail - show last N lines of a file
local fs = require("filesystem")
local tArgs = env.ARGS or {}
local nLines = 10
local sPath = nil
for _, a in ipairs(tArgs) do
  local n = a:match("^%-n(%d+)$") or a:match("^%-(%d+)$")
  if n then nLines = tonumber(n)
  elseif a:sub(1,1) ~= "-" then sPath = a end
end
if not sPath then print("Usage: tail [-n N] <file>"); return end
if sPath:sub(1,1) ~= "/" then sPath = (env.PWD or "/") .. "/" .. sPath end
sPath = sPath:gsub("//", "/")

local h = fs.open(sPath, "r")
if not h then print("tail: " .. sPath .. ": No such file"); return end
local sData = fs.read(h, math.huge) or ""
fs.close(h)

local tLines = {}
for sLine in (sData .. "\n"):gmatch("([^\n]*)\n") do
  table.insert(tLines, sLine)
end
local nStart = math.max(1, #tLines - nLines + 1)
for i = nStart, #tLines do print(tLines[i]) end