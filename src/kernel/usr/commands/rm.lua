-- rm - remove files and directories
local fs = require("filesystem")
local tArgs = env.ARGS or {}
if #tArgs == 0 then print("Usage: rm [-r] <file> [...]"); return end

local bRecursive = false
local tFiles = {}
for _, a in ipairs(tArgs) do
  if a == "-r" or a == "-rf" or a == "-f" then bRecursive = true
  else table.insert(tFiles, a) end
end

for _, sArg in ipairs(tFiles) do
  local sPath = sArg
  if sPath:sub(1,1) ~= "/" then sPath = (env.PWD or "/") .. "/" .. sPath end
  sPath = sPath:gsub("//", "/")
  if sPath == "/" or sPath == "/dev" or sPath == "/etc" then
    print("rm: refusing to remove '" .. sPath .. "'"); goto next
  end
  local bOk = fs.remove(sPath)
  if not bOk then print("rm: cannot remove '" .. sArg .. "'") end
  ::next::
end