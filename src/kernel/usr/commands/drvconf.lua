--
-- /usr/commands/drvconf.lua
-- AxisOS Driver Autoload Configuration Tool
--
-- Usage:
--   drvconf                    List configured drivers
--   drvconf list               Same as above
--   drvconf enable <name>      Enable a driver
--   drvconf disable <name>     Disable a driver
--   drvconf add <name> <path>  Add a new driver entry
--   drvconf remove <name>      Remove a driver entry
--   drvconf check              Validate dependencies
--   drvconf order              Show resolved boot load order
--   drvconf set <name> <k> <v> Set a field (priority, description)
--

local fs = require("filesystem")
local tArgs = env.ARGS or {}

local CFG_PATH = "/etc/drivers.cfg"

local C = {
    R   = "\27[37m",
    RED = "\27[31m",
    GRN = "\27[32m",
    YLW = "\27[33m",
    BLU = "\27[34m",
    MAG = "\27[35m",
    CYN = "\27[36m",
    GRY = "\27[90m",
}

-- =============================================
-- CONFIG FILE I/O
-- =============================================

local function loadConfig()
    local h = fs.open(CFG_PATH, "r")
    if not h then return nil, "Cannot open " .. CFG_PATH end
    local sData = fs.read(h, math.huge)
    fs.close(h)
    if not sData or #sData == 0 then return {}, nil end
    local f, sErr = load(sData, "drivers.cfg", "t", {})
    if not f then return nil, "Parse error: " .. tostring(sErr) end
    local bOk, tResult = pcall(f)
    if not bOk then return nil, "Exec error: " .. tostring(tResult) end
    if type(tResult) ~= "table" then return nil, "Config must return a table" end
    return tResult
end

local function saveConfig(tDrivers)
    fs.mkdir("/etc")
    local h = fs.open(CFG_PATH, "w")
    if not h then return false, "Cannot write " .. CFG_PATH end

    fs.write(h, "--\n")
    fs.write(h, "-- /etc/drivers.cfg\n")
    fs.write(h, "-- AxisOS Driver Autoload Configuration\n")
    fs.write(h, "-- Managed by drvconf. Manual edits are preserved.\n")
    fs.write(h, "--\n")
    fs.write(h, "return {\n")

    for _, tEntry in ipairs(tDrivers) do
        fs.write(h, "    {\n")
        fs.write(h, string.format('        name        = "%s",\n', tEntry.name or "?"))
        fs.write(h, string.format('        path        = "%s",\n', tEntry.path or "?"))
        fs.write(h, string.format('        enabled     = %s,\n',
            tEntry.enabled == false and "false" or "true"))
        fs.write(h, string.format('        priority    = %d,\n', tEntry.priority or 500))

        -- depends
        if tEntry.depends and #tEntry.depends > 0 then
            local tDeps = {}
            for _, d in ipairs(tEntry.depends) do
                tDeps[#tDeps + 1] = '"' .. d .. '"'
            end
            fs.write(h, '        depends     = {' .. table.concat(tDeps, ", ") .. '},\n')
        else
            fs.write(h, '        depends     = {},\n')
        end

        if tEntry.description then
            fs.write(h, string.format('        description = "%s",\n',
                tEntry.description:gsub('"', '\\"')))
        end
        fs.write(h, "    },\n")
    end

    fs.write(h, "}\n")
    fs.close(h)
    return true
end

local function findEntry(tDrivers, sName)
    for i, tEntry in ipairs(tDrivers) do
        if tEntry.name == sName then return i, tEntry end
    end
    return nil
end

-- =============================================
-- DEPENDENCY RESOLVER (mirrors PM logic)
-- =============================================

local function topoSort(tEnabled, tByName)
    local tResult  = {}
    local tVisited = {}
    local tInStack = {}
    local tErrors  = {}

    local function visit(sName, sRequestedBy)
        if tVisited[sName] then return true end
        if tInStack[sName] then
            tErrors[#tErrors + 1] = "Circular: " .. sName ..
                (sRequestedBy and (" <- " .. sRequestedBy) or "")
            return false
        end

        local tEntry = tByName[sName]
        if not tEntry then
            tErrors[#tErrors + 1] = "Missing: '" .. sName .. "'" ..
                (sRequestedBy and (" (required by '" .. sRequestedBy .. "')") or "")
            return true -- skip missing, don't cascade
        end

        tInStack[sName] = true
        for _, sDep in ipairs(tEntry.depends or {}) do
            visit(sDep, sName)
        end
        tInStack[sName] = nil
        tVisited[sName] = true
        tResult[#tResult + 1] = tEntry
        return true
    end

    local tPri = {}
    for _, e in ipairs(tEnabled) do tPri[#tPri + 1] = e end
    table.sort(tPri, function(a, b)
        return (a.priority or 500) < (b.priority or 500)
    end)

    for _, tEntry in ipairs(tPri) do
        visit(tEntry.name, nil)
    end

    return tResult, tErrors
end

-- =============================================
-- COMMANDS
-- =============================================

local function cmdList()
    local tDrivers, sErr = loadConfig()
    if not tDrivers then
        print(C.RED .. "Error: " .. C.R .. tostring(sErr))
        return
    end

    if #tDrivers == 0 then
        print(C.GRY .. "  No drivers configured." .. C.R)
        print("  Add one with: drvconf add <name> <path>")
        return
    end

    print(C.CYN .. "Configured Drivers" .. C.R .. " (" .. CFG_PATH .. ")")
    print(C.GRY .. string.rep("-", 70) .. C.R)
    print(string.format("  %s%-3s %-14s %-5s %-6s %-8s %s%s",
        C.GRY, "#", "NAME", "PRI", "STATUS", "DEPS", "PATH", C.R))

    for i, tEntry in ipairs(tDrivers) do
        local bOn = tEntry.enabled ~= false
        local sStatus = bOn and (C.GRN .. "ON ") or (C.RED .. "OFF")
        local nDeps = tEntry.depends and #tEntry.depends or 0
        local sDeps = nDeps > 0 and (C.YLW .. tostring(nDeps)) or (C.GRY .. "0")

        print(string.format("  %-3d %s%-14s%s %-5d %s%s  %s%s   %s%s%s",
            i,
            C.CYN, tEntry.name or "?", C.R,
            tEntry.priority or 500,
            sStatus, C.R,
            sDeps, C.R,
            C.GRY, tEntry.path or "?", C.R))

        if tEntry.description then
            print(string.format("      %s%s%s", C.GRY, tEntry.description, C.R))
        end
        if nDeps > 0 then
            print(string.format("      %sdepends: %s%s",
                C.GRY, table.concat(tEntry.depends, ", "), C.R))
        end
    end
end

local function cmdEnable(sName)
    if not sName then print("Usage: drvconf enable <name>"); return end
    local tDrivers, sErr = loadConfig()
    if not tDrivers then print(C.RED .. sErr .. C.R); return end
    local nIdx, tEntry = findEntry(tDrivers, sName)
    if not nIdx then print(C.RED .. "Not found: " .. sName .. C.R); return end
    tEntry.enabled = true
    saveConfig(tDrivers)
    print(C.GRN .. "Enabled: " .. C.R .. sName)
    print(C.GRY .. "  Takes effect on next boot." .. C.R)
end

local function cmdDisable(sName)
    if not sName then print("Usage: drvconf disable <name>"); return end
    local tDrivers, sErr = loadConfig()
    if not tDrivers then print(C.RED .. sErr .. C.R); return end
    local nIdx, tEntry = findEntry(tDrivers, sName)
    if not nIdx then print(C.RED .. "Not found: " .. sName .. C.R); return end
    tEntry.enabled = false
    saveConfig(tDrivers)
    print(C.YLW .. "Disabled: " .. C.R .. sName)

    -- Warn if others depend on this
    for _, tOther in ipairs(tDrivers) do
        if tOther.enabled ~= false and tOther.depends then
            for _, sDep in ipairs(tOther.depends) do
                if sDep == sName then
                    print(C.RED .. "  WARNING: '" .. tOther.name ..
                        "' depends on this driver!" .. C.R)
                end
            end
        end
    end
end

local function cmdAdd(sName, sPath, sPriority)
    if not sName or not sPath then
        print("Usage: drvconf add <name> <path> [priority]")
        return
    end

    local tDrivers, sErr = loadConfig()
    if not tDrivers then tDrivers = {} end -- create new if missing

    if findEntry(tDrivers, sName) then
        print(C.RED .. "Already exists: " .. sName .. C.R)
        print("  Use 'drvconf set " .. sName .. " path " .. sPath .. "' to change path")
        return
    end

    -- Resolve relative path
    if sPath:sub(1, 1) ~= "/" then
        sPath = (env.PWD or "/") .. "/" .. sPath
        sPath = sPath:gsub("//", "/")
    end

    -- Check file exists
    local hCheck = fs.open(sPath, "r")
    if hCheck then
        fs.close(hCheck)
    else
        print(C.YLW .. "WARNING: File not found: " .. sPath .. C.R)
        print(C.YLW .. "  Adding anyway — install the driver before rebooting." .. C.R)
    end

    tDrivers[#tDrivers + 1] = {
        name        = sName,
        path        = sPath,
        enabled     = true,
        priority    = tonumber(sPriority) or 500,
        depends     = {},
        description = nil,
    }

    saveConfig(tDrivers)
    print(C.GRN .. "Added: " .. C.R .. sName .. " → " .. sPath)
    print(C.GRY .. "  Priority: " .. (tonumber(sPriority) or 500) .. C.R)
    print(C.GRY .. "  Add dependencies: drvconf set " .. sName .. " depends dep1,dep2" .. C.R)
end

local function cmdRemove(sName)
    if not sName then print("Usage: drvconf remove <name>"); return end
    local tDrivers, sErr = loadConfig()
    if not tDrivers then print(C.RED .. sErr .. C.R); return end

    local nIdx = findEntry(tDrivers, sName)
    if not nIdx then print(C.RED .. "Not found: " .. sName .. C.R); return end

    -- Warn about dependents
    for _, tOther in ipairs(tDrivers) do
        if tOther.depends then
            for _, sDep in ipairs(tOther.depends) do
                if sDep == sName then
                    print(C.YLW .. "  Note: '" .. tOther.name ..
                        "' depends on this driver" .. C.R)
                end
            end
        end
    end

    table.remove(tDrivers, nIdx)
    saveConfig(tDrivers)
    print(C.RED .. "Removed: " .. C.R .. sName)
end

local function cmdSet(sName, sKey, sValue)
    if not sName or not sKey or not sValue then
        print("Usage: drvconf set <name> <key> <value>")
        print("  Keys: priority, path, description, depends")
        print("  Example: drvconf set mydrv priority 200")
        print("  Example: drvconf set mydrv depends internet,blkdev")
        return
    end

    local tDrivers, sErr = loadConfig()
    if not tDrivers then print(C.RED .. sErr .. C.R); return end
    local nIdx, tEntry = findEntry(tDrivers, sName)
    if not nIdx then print(C.RED .. "Not found: " .. sName .. C.R); return end

    if sKey == "priority" then
        local n = tonumber(sValue)
        if not n then print(C.RED .. "Priority must be a number" .. C.R); return end
        tEntry.priority = n
    elseif sKey == "path" then
        tEntry.path = sValue
    elseif sKey == "description" or sKey == "desc" then
        tEntry.description = sValue
    elseif sKey == "depends" or sKey == "deps" then
        local tDeps = {}
        if sValue ~= "" and sValue ~= "none" then
            for sDep in sValue:gmatch("[^,]+") do
                local sTrimmed = sDep:match("^%s*(.-)%s*$")
                if #sTrimmed > 0 then
                    tDeps[#tDeps + 1] = sTrimmed
                end
            end
        end
        tEntry.depends = tDeps
    else
        print(C.RED .. "Unknown key: " .. sKey .. C.R)
        print("  Valid keys: priority, path, description, depends")
        return
    end

    saveConfig(tDrivers)
    print(C.GRN .. "Updated: " .. C.R .. sName .. "." .. sKey .. " = " .. sValue)
end

local function cmdCheck()
    local tDrivers, sErr = loadConfig()
    if not tDrivers then print(C.RED .. sErr .. C.R); return end

    print(C.CYN .. "Dependency Check" .. C.R)
    print(C.GRY .. string.rep("-", 50) .. C.R)

    local tEnabled = {}
    local tByName  = {}
    local tAllByName = {}

    for _, tEntry in ipairs(tDrivers) do
        tAllByName[tEntry.name] = tEntry
        if tEntry.enabled ~= false then
            tEnabled[#tEnabled + 1] = tEntry
            tByName[tEntry.name] = tEntry
        end
    end

    local nIssues = 0

    -- Check each enabled driver
    for _, tEntry in ipairs(tEnabled) do
        local tProblems = {}

        -- File exists?
        local hTest = fs.open(tEntry.path, "r")
        if hTest then
            fs.close(hTest)
        else
            tProblems[#tProblems + 1] = C.RED .. "file not found: " .. tEntry.path .. C.R
        end

        -- Dependencies met?
        for _, sDep in ipairs(tEntry.depends or {}) do
            if not tByName[sDep] then
                if tAllByName[sDep] then
                    tProblems[#tProblems + 1] = C.YLW .. "dep '" .. sDep ..
                        "' is disabled" .. C.R
                else
                    tProblems[#tProblems + 1] = C.RED .. "dep '" .. sDep ..
                        "' not configured" .. C.R
                end
            end
        end

        if #tProblems == 0 then
            print("  " .. C.GRN .. "OK" .. C.R .. "  " .. tEntry.name)
        else
            nIssues = nIssues + #tProblems
            print("  " .. C.RED .. "!!" .. C.R .. "  " .. tEntry.name)
            for _, sP in ipairs(tProblems) do
                print("       " .. sP)
            end
        end
    end

    -- Cycle check
    local _, tErrors = topoSort(tEnabled, tByName)
    if tErrors and #tErrors > 0 then
        print("")
        for _, sE in ipairs(tErrors) do
            if sE:find("Circular") then
                nIssues = nIssues + 1
                print("  " .. C.RED .. sE .. C.R)
            end
        end
    end

    print("")
    if nIssues == 0 then
        print(C.GRN .. "  All checks passed." .. C.R)
    else
        print(C.YLW .. "  " .. nIssues .. " issue(s) found." .. C.R)
    end
end

local function cmdOrder()
    local tDrivers, sErr = loadConfig()
    if not tDrivers then print(C.RED .. sErr .. C.R); return end

    local tEnabled = {}
    local tByName  = {}
    for _, tEntry in ipairs(tDrivers) do
        if tEntry.enabled ~= false then
            tEnabled[#tEnabled + 1] = tEntry
            tByName[tEntry.name] = tEntry
        end
    end

    local tSorted, tErrors = topoSort(tEnabled, tByName)

    print(C.CYN .. "Resolved Boot Load Order" .. C.R)
    print(C.GRY .. string.rep("-", 50) .. C.R)

    if tErrors and #tErrors > 0 then
        for _, sE in ipairs(tErrors) do
            print("  " .. C.YLW .. "WARN: " .. sE .. C.R)
        end
        print("")
    end

    for i, tEntry in ipairs(tSorted) do
        local sDeps = ""
        if tEntry.depends and #tEntry.depends > 0 then
            sDeps = C.GRY .. " (after: " ..
                table.concat(tEntry.depends, ", ") .. ")" .. C.R
        end
        print(string.format("  %s%2d.%s %-14s %spri=%d%s%s",
            C.GRN, i, C.R,
            tEntry.name,
            C.GRY, tEntry.priority or 500, C.R,
            sDeps))
    end

    print("")
    print(C.GRY .. "  " .. #tSorted .. " driver(s) will load at boot." .. C.R)
end

local function cmdHelp()
    print(C.CYN .. "drvconf" .. C.R .. " — Driver Autoload Configuration")
    print("")
    print("  drvconf                        List all configured drivers")
    print("  drvconf enable <name>          Enable a driver for boot")
    print("  drvconf disable <name>         Disable a driver")
    print("  drvconf add <name> <path> [p]  Add new driver (p=priority)")
    print("  drvconf remove <name>          Remove a driver entry")
    print("  drvconf set <name> <k> <v>     Set field (priority/path/depends/desc)")
    print("  drvconf check                  Validate all dependencies")
    print("  drvconf order                  Show resolved boot load order")
    print("")
    print("  " .. C.GRY .. "Config file: " .. CFG_PATH .. C.R)
    print("")
    print("  " .. C.CYN .. "Examples:" .. C.R)
    print("    drvconf add blkdev /drivers/blkdev.sys.lua 200")
    print("    drvconf add hbm_rbmk /sys/drivers/hbm_rbmk.sys.lua 400")
    print("    drvconf set hbm_rbmk depends blkdev")
    print("    drvconf set hbm_rbmk desc \"HBM RBMK reactor driver\"")
    print("    drvconf disable hbm_rbmk")
    print("    drvconf check")
    print("    drvconf order")
end

-- =============================================
-- DISPATCH
-- =============================================

local sCmd = tArgs[1]

if not sCmd or sCmd == "list" or sCmd == "ls" then cmdList()
elseif sCmd == "enable"  then cmdEnable(tArgs[2])
elseif sCmd == "disable" then cmdDisable(tArgs[2])
elseif sCmd == "add"     then cmdAdd(tArgs[2], tArgs[3], tArgs[4])
elseif sCmd == "remove" or sCmd == "rm" then cmdRemove(tArgs[2])
elseif sCmd == "set"     then cmdSet(tArgs[2], tArgs[3], tArgs[4])
elseif sCmd == "check"   then cmdCheck()
elseif sCmd == "order"   then cmdOrder()
elseif sCmd == "-h" or sCmd == "--help" or sCmd == "help" then cmdHelp()
else
    print(C.RED .. "Unknown command: " .. sCmd .. C.R)
    cmdHelp()
end