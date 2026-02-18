-- cp - copy files
local fs = require("filesystem")
local tArgs = env.ARGS or {}
if #tArgs < 2 then print("Usage: cp <source> <dest>"); return end

local sSrc, sDst = tArgs[1], tArgs[2]
if sSrc:sub(1,1) ~= "/" then sSrc = (env.PWD or "/") .. "/" .. sSrc end
if sDst:sub(1,1) ~= "/" then sDst = (env.PWD or "/") .. "/" .. sDst end
sSrc = sSrc:gsub("//", "/")
sDst = sDst:gsub("//", "/")

local hIn = fs.open(sSrc, "r")
if not hIn then print("cp: " .. sSrc .. ": No such file"); return end
local sData = fs.read(hIn, math.huge) or ""
fs.close(hIn)

local hOut = fs.open(sDst, "w")
if not hOut then print("cp: cannot create " .. sDst); return end
fs.write(hOut, sData)
fs.close(hOut)