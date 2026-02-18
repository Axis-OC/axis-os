-- head - show first N lines of a file
local fs = require("filesystem")
local tArgs = env.ARGS or {}
local nLines = 10
local sPath = nil
for _, a in ipairs(tArgs) do
  local n = a:match("^%-n(%d+)$") or a:match("^%-(%d+)$")
  if n then nLines = tonumber(n)
  elseif a:sub(1,1) ~= "-" then sPath = a end
end
if not sPath then print("Usage: head [-n N] <file>"); return end
if sPath:sub(1,1) ~= "/" then sPath = (env.PWD or "/") .. "/" .. sPath end
sPath = sPath:gsub("//", "/")

local h = fs.open(sPath, "r")
if not h then print("head: " .. sPath .. ": No such file"); return end
local sData = fs.read(h, math.huge) or ""
fs.close(h)

local nCount = 0
for sLine in (sData .. "\n"):gmatch("([^\n]*)\n") do
  nCount = nCount + 1
  if nCount > nLines then break end
  print(sLine)
end