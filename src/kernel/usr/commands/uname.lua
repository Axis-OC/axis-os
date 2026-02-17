local tArgs = env.ARGS or {}
local bAll = false
for _, a in ipairs(tArgs) do if a == "-a" then bAll = true end end

if bAll then
    print("AxisOS Xen XKA 0.3 " .. (env.HOSTNAME or "localhost") .. " Lua5.2 OpenComputers")
else
    print("AxisOS")
end