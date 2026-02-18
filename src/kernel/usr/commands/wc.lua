-- wc - word, line, byte count
local fs = require("filesystem")
local tArgs = env.ARGS or {}
if #tArgs == 0 then print("Usage: wc <file> [...]"); return end

local nTL, nTW, nTB = 0, 0, 0
for _, sArg in ipairs(tArgs) do
  local sPath = sArg
  if sPath:sub(1,1) ~= "/" then sPath = (env.PWD or "/") .. "/" .. sPath end
  sPath = sPath:gsub("//", "/")
  local h = fs.open(sPath, "r")
  if not h then print("wc: " .. sArg .. ": No such file"); goto next end
  local sData = fs.read(h, math.huge) or ""
  fs.close(h)
  local nL = 0; for _ in sData:gmatch("\n") do nL = nL + 1 end
  local nW = 0; for _ in sData:gmatch("%S+") do nW = nW + 1 end
  local nB = #sData
  nTL = nTL + nL; nTW = nTW + nW; nTB = nTB + nB
  print(string.format("  %5d %5d %5d  %s", nL, nW, nB, sArg))
  ::next::
end
if #tArgs > 1 then print(string.format("  %5d %5d %5d  total", nTL, nTW, nTB)) end