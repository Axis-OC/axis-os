-- cat.lua (fixed argument parsing)
local fs = require("filesystem")
local tArgs = env.ARGS

if not tArgs or #tArgs == 0 then
  print("Usage: cat <filename> [...]")
  return
end

for _, sArg in ipairs(tArgs) do
  if sArg:sub(1, 1) == "-" then
    print("cat: unknown option -- '" .. sArg:sub(2) .. "'")
    return
  end

  local sPath = sArg
  if sPath:sub(1,1) ~= "/" then
    sPath = (env.PWD or "/") .. (env.PWD == "/" and "" or "/") .. sPath
  end
  sPath = sPath:gsub("//", "/")

  local hFile = fs.open(sPath, "r")
  if hFile then
    local sData = fs.read(hFile, math.huge)
    if sData then io.write(sData) end
    fs.close(hFile)
  else
    print("cat: " .. sPath .. ": No such file or directory")
  end
end