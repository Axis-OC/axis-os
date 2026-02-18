-- touch - create empty file or update timestamp
local fs = require("filesystem")
local tArgs = env.ARGS or {}
if #tArgs == 0 then print("Usage: touch <file> [...]"); return end

for _, sArg in ipairs(tArgs) do
  local sPath = sArg
  if sPath:sub(1,1) ~= "/" then sPath = (env.PWD or "/") .. "/" .. sPath end
  sPath = sPath:gsub("//", "/")
  local h = fs.open(sPath, "a")
  if h then fs.close(h) else print("touch: cannot touch '" .. sArg .. "'") end
end