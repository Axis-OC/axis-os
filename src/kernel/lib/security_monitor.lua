--
-- /lib/security_monitor.lua
-- AxisOS Security Reference Monitor — permission checks, access audit
-- Split from pipeline_manager.lua (Feature 5)
--

local oSec = {}

local tPermCache = nil
local g_oRootFs = nil

function oSec.Init(oRootFs)
    g_oRootFs = oRootFs
    oSec.LoadPerms()
    syscall("kernel_log", "[SEC_MON] Security Monitor initialized")
end

function oSec.LoadPerms()
    if not g_oRootFs then tPermCache = {}; return end
    local bOk, h = syscall("raw_component_invoke", g_oRootFs.address, "open", "/etc/perms.lua", "r")
    if bOk and h then
        local _, d = syscall("raw_component_invoke", g_oRootFs.address, "read", h, math.huge)
        syscall("raw_component_invoke", g_oRootFs.address, "close", h)
        if d then
            local f = load(d, "perms", "t", {})
            if f then tPermCache = f() end
        end
    end
    if not tPermCache then tPermCache = {} end
end

function oSec.SavePerms()
    if not tPermCache or not g_oRootFs then return end
    local sData = "return {\n"
    for sPath, tInfo in pairs(tPermCache) do
        sData = sData .. string.format('  ["%s"] = { uid = %d, gid = %d, mode = %d },\n',
            sPath, tInfo.uid or 0, tInfo.gid or 0, tInfo.mode or 755)
    end
    sData = sData .. "}"
    local bOk, h = syscall("raw_component_invoke", g_oRootFs.address, "open", "/etc/perms.lua", "w")
    if bOk and h then
        syscall("raw_component_invoke", g_oRootFs.address, "write", h, sData)
        syscall("raw_component_invoke", g_oRootFs.address, "close", h)
    end
end

function oSec.CheckAccess(nPid, sPath, sMode)
    local nUid = syscall("process_get_uid", nPid) or 1000
    if nUid == 0 then return true end
    if not tPermCache then oSec.LoadPerms() end
    local tP = tPermCache[sPath] or { uid = 0, gid = 0, mode = 755 }
    local nReq = (sMode == "w" or sMode == "a") and 2 or 4
    local sModeStr = tostring(tP.mode)
    local nPermDigit = (nUid == tP.uid)
        and tonumber(sModeStr:sub(1, 1))
        or tonumber(sModeStr:sub(3, 3))
    if nReq == 4 then return nPermDigit >= 4
    elseif nReq == 2 then
        return nPermDigit == 2 or nPermDigit == 3 or nPermDigit == 6 or nPermDigit == 7
    end
    return false
end

function oSec.Chmod(sPath, nMode, nCallerPid)
    local nUid = syscall("process_get_uid", nCallerPid) or 1000
    if not tPermCache then oSec.LoadPerms() end
    local tEntry = tPermCache[sPath] or { uid = nUid, gid = 0, mode = 755 }
    if nUid ~= 0 and tEntry.uid ~= nUid then return nil, "Not owner" end
    tEntry.mode = nMode
    tPermCache[sPath] = tEntry
    oSec.SavePerms()
    return true
end

return oSec