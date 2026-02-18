-- grep - search for text in files
local fs = require("filesystem")
local tArgs = env.ARGS or {}
if #tArgs < 2 then print("Usage: grep <text> <file> [...]"); return end

local sNeedle = tArgs[1]
local C_R = "\27[37m"
local C_M = "\27[31m"
local bMulti = (#tArgs > 2)

for i = 2, #tArgs do
  local sPath = tArgs[i]
  if sPath:sub(1,1) ~= "/" then sPath = (env.PWD or "/") .. "/" .. sPath end
  sPath = sPath:gsub("//", "/")

  local h = fs.open(sPath, "r")
  if not h then print("grep: " .. tArgs[i] .. ": No such file"); goto next end
  local sData = fs.read(h, math.huge) or ""
  fs.close(h)

  for sLine in (sData .. "\n"):gmatch("([^\n]*)\n") do
    if sLine:find(sNeedle, 1, true) then
      local sPrefix = bMulti and (C_M .. tArgs[i] .. C_R .. ":") or ""
      -- highlight matches
      local sOut, nPos = "", 1
      while nPos <= #sLine do
        local nS, nE = sLine:find(sNeedle, nPos, true)
        if not nS then sOut = sOut .. sLine:sub(nPos); break end
        sOut = sOut .. sLine:sub(nPos, nS - 1) .. C_M .. sLine:sub(nS, nE) .. C_R
        nPos = nE + 1
      end
      print(sPrefix .. sOut)
    end
  end
  ::next::
end