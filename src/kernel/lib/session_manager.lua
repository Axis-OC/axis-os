--
-- /lib/session_manager.lua
-- AxisOS Session Manager — boot sequencing, log rotation, init spawn
-- Split from pipeline_manager.lua (Feature 5)
--

local oSess = {}

local g_oRootFs = nil
local g_tSysConfig = nil
local g_tLogState = nil
local g_nRingFsId = nil

function oSess.Init(oRootFs)
    g_oRootFs = oRootFs
    g_tSysConfig = oSess._loadSysConfig()
    syscall("kernel_log", "[SESS] Session Manager initialized")
end

function oSess._loadSysConfig(oRootFsOverride)
    local oFs = oRootFsOverride or g_oRootFs
    if not oFs then return {} end
    local bOk, h = syscall("raw_component_invoke", oFs.address, "open", "/etc/sys.cfg", "r")
    if not bOk or not h then return {} end
    local _, d = syscall("raw_component_invoke", oFs.address, "read", h, math.huge)
    syscall("raw_component_invoke", oFs.address, "close", h)
    if not d or type(d) ~= "string" then return {} end
    local f = load(d, "sys.cfg", "t", {})
    if not f then return {} end
    local bP, tR = pcall(f)
    return (bP and type(tR) == "table") and tR or {}
end

function oSess.SetupLogRotation()
    local tLog = g_tSysConfig and g_tSysConfig.logging
    if not tLog or not tLog.enable_log_rotation_saver then return nil end
    local sLogDir = tLog.log_dir or "/log"
    local sVblDir = tLog.vbl_dir or "/vbl"
    local nMax = tLog.max_log_files or 5
    pcall(function() syscall("raw_component_invoke", g_oRootFs.address, "makeDirectory", sLogDir) end)
    pcall(function() syscall("raw_component_invoke", g_oRootFs.address, "makeDirectory", sVblDir) end)
    -- Simplified: just open new log files with incrementing numbers
    local sNumStr = string.format("%03d", math.random(1, 999))
    local sLogPath = sLogDir .. "/syslog_" .. sNumStr .. ".log"
    local sVblPath = sVblDir .. "/syslog_" .. sNumStr .. ".vbl"
    local _, hLog = syscall("raw_component_invoke", g_oRootFs.address, "open", sLogPath, "w")
    local _, hVbl = syscall("raw_component_invoke", g_oRootFs.address, "open", sVblPath, "w")
    g_tLogState = { hLogFile = hLog, hVblFile = hVbl, sLogPath = sLogPath, sVblPath = sVblPath }
    return g_tLogState
end

function oSess.DrainKernelLog()
    local sLog = syscall("kernel_get_boot_log")
    if not sLog or #sLog == 0 then return end
    if g_tLogState and g_tLogState.hVblFile then
        syscall("raw_component_invoke", g_oRootFs.address, "write", g_tLogState.hVblFile, sLog .. "\n")
    end
end

function oSess.SpawnInit(sInitPath)
    sInitPath = sInitPath or "/bin/init.lua"
    syscall("kernel_log", "[SESS] Spawning " .. sInitPath)
    local nPid, sErr = syscall("process_spawn", sInitPath, 3)
    if nPid then
        syscall("kernel_log", "[SESS] Init spawned as PID " .. nPid)
    else
        syscall("kernel_log", "[SESS] FAILED: " .. tostring(sErr))
    end
    return nPid
end

function oSess.GetConfig() return g_tSysConfig end

return oSess