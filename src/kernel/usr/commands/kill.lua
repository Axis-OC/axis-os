-- /usr/commands/kill.lua
local tArgs = env.ARGS or {}
if #tArgs < 1 then print("Usage: kill <pid>"); return end

local nTarget = tonumber(tArgs[1])
if not nTarget then print("kill: not a number: " .. tArgs[1]); return end

local bOk, sErr = syscall("process_kill", nTarget)
if bOk then
    print("Killed PID " .. nTarget)
else
    print("kill: " .. tostring(sErr))
end