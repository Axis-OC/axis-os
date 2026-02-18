-- mv - move/rename files
local fs = require("filesystem")
local tArgs = env.ARGS or {}
if #tArgs < 2 then print("Usage: mv <source> <dest>"); return end

local sSrc, sDst = tArgs[1], tArgs[2]
if sSrc:sub(1,1) ~= "/" then sSrc = (env.PWD or "/") .. "/" .. sSrc end
if sDst:sub(1,1) ~= "/" then sDst = (env.PWD or "/") .. "/" .. sDst end
sSrc = sSrc:gsub("//", "/")
sDst = sDst:gsub("//", "/")

local hIn = fs.open(sSrc, "r")
if not hIn then print("mv: " .. sSrc .. ": No such file"); return end
local sData = fs.read(hIn, math.huge) or ""
fs.close(hIn)

local hOut = fs.open(sDst, "w")
if not hOut then print("mv: cannot create " .. sDst); return end
fs.write(hOut, sData)
fs.close(hOut)
fs.remove(sSrc)