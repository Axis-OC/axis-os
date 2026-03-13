--
-- /usr/commands/logread.lua
-- Read system logs (ringfs live buffer or .vbl files)
--
-- Usage:
--   logread               Live ring buffer
--   logread -f <file>     Read a .vbl/.log file
--   logread -l            List available log files
--   logread -a            All .vbl files concatenated
--

local fs = require("filesystem")
local tArgs = env.ARGS or {}

local C = {R="\27[37m", CYN="\27[36m", GRY="\27[90m", YLW="\27[33m"}

local sMode = "live"
local sFile = nil

local i = 1
while i <= #tArgs do
    local a = tArgs[i]
    if a == "-f" then
        sMode = "file"; i = i + 1; sFile = tArgs[i]
    elseif a == "-l" then
        sMode = "list"
    elseif a == "-a" then
        sMode = "all_vbl"
    elseif a == "-h" then
        print(C.CYN .. "logread" .. C.R .. " — System log reader")
        print("  logread          Live ring buffer (/dev/ringlog)")
        print("  logread -f FILE  Read specific .vbl or .log file")
        print("  logread -l       List available log files")
        print("  logread -a       All .vbl files")
        return
    end
    i = i + 1
end

if sMode == "list" then
    print(C.CYN .. "Available log files:" .. C.R)
    print("")
    for _, sDir in ipairs({"/log", "/vbl"}) do
        local tList = fs.list(sDir)
        if tList then
            for _, sName in ipairs(tList) do
                local sClean = sName:gsub("/$", "")
                local sPath = sDir .. "/" .. sClean
                print(string.format("  %s%-30s%s", C.YLW, sPath, C.R))
            end
        end
    end
    return
end

if sMode == "file" then
    if not sFile then print("logread: missing filename after -f"); return end
    if sFile:sub(1,1) ~= "/" then sFile = (env.PWD or "/") .. "/" .. sFile end
    local h = fs.open(sFile, "r")
    if not h then print("logread: cannot open " .. sFile); return end
    local sData = fs.read(h, math.huge)
    fs.close(h)
    if sData then print(sData) else print("(empty)") end
    return
end

if sMode == "all_vbl" then
    local tList = fs.list("/vbl")
    if not tList then print("No /vbl directory"); return end
    table.sort(tList)
    for _, sName in ipairs(tList) do
        local sClean = sName:gsub("/$", "")
        if sClean:match("%.vbl$") then
            print(C.CYN .. "=== /vbl/" .. sClean .. " ===" .. C.R)
            local h = fs.open("/vbl/" .. sClean, "r")
            if h then
                local sData = fs.read(h, math.huge)
                fs.close(h)
                if sData then print(sData) end
            end
        end
    end
    return
end

-- Default: live ring buffer
local hLog = fs.open("/dev/ringlog", "r")
if not hLog then print("Cannot open /dev/ringlog"); return end
local sData = fs.read(hLog, math.huge)
fs.close(hLog)
if sData and #sData > 0 then print(sData)
else print("(empty)") end