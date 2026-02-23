--
-- /usr/commands/appmgr.lua
-- AxisOS Application Manager CLI
--
local appmgr = require("appmgr")
local args = env.ARGS or {}
local cmd = args[1]

local C = {R="\27[37m",G="\27[32m",Y="\27[33m",C="\27[36m",E="\27[31m",D="\27[90m"}

if not cmd or cmd == "help" then
    print(C.C .. "appmgr" .. C.R .. " — AxisOS Application Manager")
    print("")
    print("  " .. C.Y .. "appmgr list" .. C.R .. "                 List installed apps")
    print("  " .. C.Y .. "appmgr info <name>" .. C.R .. "         Show app info")
    print("  " .. C.Y .. "appmgr run <name>" .. C.R .. "          Launch app (creates AWC window)")
    print("  " .. C.Y .. "appmgr create <name>" .. C.R .. "       Scaffold a new app")
    print("")
    print("  Apps are stored in " .. C.C .. "/opt/apps/<name>/" .. C.R)
    return
end

if cmd == "list" then
    local tApps = appmgr.list()
    if #tApps == 0 then
        print(C.D .. "  No apps installed." .. C.R)
        print("  Create one: " .. C.Y .. "appmgr create myapp" .. C.R)
        return
    end
    print(string.format("  %s%-16s %-8s %-10s %s%s",
        C.D, "NAME", "VERSION", "CATEGORY", "DESCRIPTION", C.R))
    for _, t in ipairs(tApps) do
        print(string.format("  %s%-16s%s %-8s %-10s %s",
            C.Y, t._name or "?", C.R,
            t.version or "?",
            t.category or "?",
            t.description or ""))
    end

elseif cmd == "info" then
    local sName = args[2]
    if not sName then print(C.E .. "Usage: appmgr info <name>" .. C.R); return end
    local tM, sErr = appmgr.getManifest(sName)
    if not tM then print(C.E .. sErr .. C.R); return end
    print(C.C .. "App: " .. C.R .. (tM.name or sName))
    print("  Version:     " .. (tM.version or "?"))
    print("  Description: " .. (tM.description or ""))
    print("  Author:      " .. (tM.author or "?"))
    print("  Entry:       " .. (tM.entry or "main.lua"))
    print("  Category:    " .. (tM.category or "?"))
    print("  Icon:        " .. (tM.icon or "?"))
    print("  Directory:   " .. (tM._dir or "?"))

elseif cmd == "run" then
    local sName = args[2]
    if not sName then print(C.E .. "Usage: appmgr run <name>" .. C.R); return end
    local nPid, sErr = appmgr.run(sName)
    if nPid then
        print(C.G .. "Launched '" .. sName .. "' as PID " .. nPid .. C.R)
    else
        print(C.E .. sErr .. C.R)
    end

elseif cmd == "create" then
    local sName = args[2]
    if not sName then print(C.E .. "Usage: appmgr create <name>" .. C.R); return end
    local bOk, sDir = appmgr.create(sName)
    if bOk then
        print(C.G .. "Created app scaffold at " .. sDir .. C.R)
        print("  Edit: " .. C.Y .. sDir .. "/main.lua" .. C.R)
        print("  Run:  " .. C.Y .. "appmgr run " .. sName .. C.R)
    else
        print(C.E .. "Failed to create app" .. C.R)
    end

else
    print(C.E .. "Unknown command: " .. cmd .. C.R)
    print("Run " .. C.C .. "appmgr help" .. C.R)
end