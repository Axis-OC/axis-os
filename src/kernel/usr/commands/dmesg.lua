--
-- /usr/commands/dmesg.lua
-- AxisOS Kernel Message Buffer
--
-- Usage:
--   dmesg                    Show all messages
--   dmesg -n <count>         Last N messages
--   dmesg -l <level>         Filter by level
--   dmesg -f                 Follow (live tail)
--   dmesg -c                 Clear buffer (Ring 0-1 only)
--   dmesg -s                 Show statistics
--   dmesg -T                 Human-readable timestamps
--   dmesg --levels           List available log levels
--   dmesg -w                 Wrap long lines (default: truncate)
--

local tArgs = env.ARGS or {}

local C = {
    R="\27[37m", RED="\27[31m", GRN="\27[32m", YLW="\27[33m",
    BLU="\27[34m", MAG="\27[35m", CYN="\27[36m", GRY="\27[90m",
}

local tLevelColors = {
    ok    = C.GRN,
    fail  = C.RED,
    info  = C.CYN,
    warn  = C.YLW,
    dev   = C.BLU,
    debug = C.GRY,
    sec   = C.MAG,
    sched = "\27[34m",
    ipc   = "\27[34m",
    drv   = "\27[33m",
    vfs   = "\27[32m",
    mem   = "\27[33m",
    proc  = "\27[32m",
    none  = C.R,
}

local tLevelTags = {
    ok="  OK  ", fail=" FAIL ", info=" INFO ", warn=" WARN ",
    dev=" DEV  ", debug="DEBUG ", sec=" SEC  ", sched="SCHED ",
    ipc=" IPC  ", drv=" DRV  ", vfs=" VFS  ", mem=" MEM  ",
    proc=" PROC ", none="      ",
}

-- Parse args
local nCount      = nil
local sLevel      = nil
local bFollow     = false
local bClear      = false
local bStats      = false
local bHumanTime  = false
local bWrap       = false
local bListLevels = false

local i = 1
while i <= #tArgs do
    local a = tArgs[i]
    if a == "-n" then
        i = i + 1; nCount = tonumber(tArgs[i]) or 50
    elseif a == "-l" then
        i = i + 1; sLevel = tArgs[i]
    elseif a == "-f" or a == "--follow" then
        bFollow = true
    elseif a == "-c" or a == "--clear" then
        bClear = true
    elseif a == "-s" or a == "--stats" then
        bStats = true
    elseif a == "-T" then
        bHumanTime = true
    elseif a == "-w" then
        bWrap = true
    elseif a == "--levels" then
        bListLevels = true
    elseif a == "-h" or a == "--help" then
        print(C.CYN .. "dmesg" .. C.R .. " — Kernel message buffer")
        print("")
        print("  dmesg                Show all messages")
        print("  dmesg -n 50          Last 50 messages")
        print("  dmesg -l fail        Filter by level")
        print("  dmesg -l sec         Security events only")
        print("  dmesg -f             Follow (live tail)")
        print("  dmesg -c             Clear buffer (privileged)")
        print("  dmesg -s             Buffer statistics")
        print("  dmesg -T             Human-readable timestamps")
        print("  dmesg --levels       List available levels")
        print("")
        print("  Levels: debug dev sched ipc info drv vfs")
        print("          mem proc warn ok sec fail")
        return
    end
    i = i + 1
end

-- --levels
if bListLevels then
    print(C.CYN .. "Available log levels:" .. C.R)
    print("")
    local tLevels = {
        {"debug",  "Verbose internal state"},
        {"dev",    "Developer diagnostics"},
        {"sched",  "Scheduler/preemption events"},
        {"ipc",    "IPC subsystem events"},
        {"info",   "General informational"},
        {"drv",    "Driver lifecycle"},
        {"vfs",    "Filesystem operations"},
        {"mem",    "Memory management"},
        {"proc",   "Process lifecycle"},
        {"warn",   "Warnings"},
        {"ok",     "Success confirmations"},
        {"sec",    "Security events"},
        {"fail",   "Failures and errors"},
    }
    for _, t in ipairs(tLevels) do
        local sC = tLevelColors[t[1]] or C.R
        print(string.format("  %s%-7s%s %s", sC, t[1], C.R, t[2]))
    end
    return
end

-- -c clear
if bClear then
    local nCleared = syscall("dmesg_clear")
    if nCleared then
        print(C.GRN .. "Cleared " .. nCleared .. " entries" .. C.R)
    else
        print(C.RED .. "Permission denied (Ring 0-1 only)" .. C.R)
    end
    return
end

-- -s stats
if bStats then
    local tS = syscall("dmesg_stats")
    if not tS then print("dmesg: unavailable"); return end
    
    print(C.CYN .. "Kernel Message Buffer Statistics" .. C.R)
    print(C.GRY .. string.rep("-", 40) .. C.R)
    print(string.format("  Total entries:   %d / %d", tS.nTotal, tS.nMaxSize))
    print(string.format("  Sequence range:  %d — %d", tS.nFirstSeq, tS.nLastSeq))
    print("")
    print(C.CYN .. "  Messages by level:" .. C.R)
    
    -- Sort by count descending
    local tSorted = {}
    for sLvl, nCnt in pairs(tS.tLevelCounts or {}) do
        tSorted[#tSorted + 1] = {level = sLvl, count = nCnt}
    end
    table.sort(tSorted, function(a, b) return a.count > b.count end)
    
    for _, t in ipairs(tSorted) do
        local sC = tLevelColors[t.level] or C.R
        local nPct = math.floor((t.count / math.max(tS.nTotal, 1)) * 100)
        local nBar = math.floor(nPct / 5)
        print(string.format("    %s%-7s%s %4d  %s%s%s %d%%",
            sC, t.level, C.R, t.count,
            sC, string.rep("█", nBar), C.R, nPct))
    end
    return
end

-- Format one entry
local function formatEntry(tEntry)
    local sC = tLevelColors[tEntry.level] or C.R
    local sTag = tLevelTags[tEntry.level] or tEntry.level

    local sTime
    if bHumanTime then
        local nS = math.floor(tEntry.time)
        local nH = math.floor(nS / 3600)
        local nM = math.floor((nS % 3600) / 60)
        local nSec = nS % 60
        local nMs = math.floor((tEntry.time % 1) * 1000)
        sTime = string.format("%02d:%02d:%02d.%03d", nH, nM, nSec, nMs)
    else
        sTime = string.format("%9.4f", tEntry.time)
    end

    local sPid = ""
    if tEntry.pid and tEntry.pid > 0 then
        sPid = string.format(" P%-3d", tEntry.pid)
    end

    return string.format("%s[%s]%s %s[%s]%s%s%s %s",
        C.GRY, sTime, C.R,
        sC, sTag, C.R,
        C.GRY, sPid, C.R) .. " " .. tEntry.msg
end

-- Normal display / follow
local nLastSeq = 0

local function showMessages()
    local tEntries = syscall("dmesg_read", nLastSeq, nCount or 500, sLevel)
    if not tEntries or #tEntries == 0 then return 0 end
    
    for _, tEntry in ipairs(tEntries) do
        print(formatEntry(tEntry))
        if tEntry.seq > nLastSeq then
            nLastSeq = tEntry.seq
        end
    end
    return #tEntries
end

if bFollow then
    print(C.CYN .. "Following kernel messages (Ctrl+C to stop)..." .. C.R)
    print("")
    -- Show existing first
    showMessages()
    -- Then poll
    while true do
        local nNew = showMessages()
        if nNew == 0 then
            syscall("process_yield")
        end
    end
else
    local nShown = showMessages()
    if nShown == 0 then
        print(C.GRY .. "(no messages" ..
            (sLevel and (" matching level '" .. sLevel .. "'") or "") ..
            ")" .. C.R)
    end
end