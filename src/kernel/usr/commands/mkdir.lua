-- mkdir - create directories
local fs = require("filesystem")
local tArgs = env.ARGS or {}
if #tArgs == 0 then print("Usage: mkdir <dir> [...]"); return end

for _, sArg in ipairs(tArgs) do
  local sPath = sArg
  if sPath:sub(1,1) ~= "/" then sPath = (env.PWD or "/") .. "/" .. sPath end
  sPath = sPath:gsub("//", "/")
  local bOk = fs.mkdir(sPath)
  if not bOk then print("mkdir: cannot create '" .. sArg .. "'") end
end