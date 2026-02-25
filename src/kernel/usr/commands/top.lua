--
-- /usr/commands/top.lua
-- Authentic htop clone for AxisOS
-- Utilizes the XE UI Engine & Native Preemptive Scheduler
--

local xe = require("xe")
local fs = require("filesystem")
local computer = require("computer")

-- ==========================================
-- THEME & CONTEXT SETUP
-- ==========================================

local htop_theme = {
    bg         = 0x000000,
    fg         = 0xE0E0E0,
    title      = 0x00FF00,
    dim        = 0x666666,
    bar_bg     = 0x00AAAA,
    bar_fg     = 0x000000,
    sel_bg     = 0x00AAAA,
    sel_fg     = 0x000000,
    cpu_bar    = 0x00FF00,
    mem_bar    = 0xAAAA00,
    meter_bg   = 0x222222,
    border     = 0x555555,
    input_bg   = 0x000000,
    input_fg   = 0xFFFFFF,
    input_abg  = 0x222222,
    input_afg  = 0xFFFFFF,
    err        = 0xFF5555,
    tree_line  = 0x555555,
}

local ctx = xe.createContext({
    theme = htop_theme,
    extensions = {
        "XE_ui_shadow_buffering_render_batch",
        "XE_ui_diff_render_feature",
        "XE_ui_imgui_navigation",
        "XE_ui_dirty_row_tracking",
        "XE_ui_run_length_grouping",
        "XE_ui_modal_prebuilt",
        "XE_ui_command_palette",
        "XE_ui_toast"
    }
})

if not ctx then
    print("Failed to initialize XE context")
    return
end

local W, H = ctx.W, ctx.H
local bRunning = true

-- ==========================================
-- STATE
-- ==========================================

local tUidMap = {}
local tPrevCpu = {}
local nPrevUptime = computer.uptime()
local nLastRefresh = 0
local REFRESH_RATE = 1.0

local tList = {}
local tSortedList = {}
local tTreePrefixes = {}
local nTotalCpu = 0
local tMem = { nTotal = 1, nFree = 1, nUsed = 0, nUsedPct = 0 }

-- Load Averages (EMA simulation)
local nLoad1, nLoad5, nLoad15 = 0, 0, 0

local sSortCol = "cpu"
local bSortDesc = true
local bTreeMode = false
local sFilter = ""
local bSearchMode = false

-- Status character mapping
local tStatusChar = {
    running  = "R",
    ready    = "S",
    sleeping = "S",
    dead     = "Z",
    stopped  = "T"
}

-- Status color mapping
local tStatusColor = {
    R = 0x55FF55,
    S = 0xE0E0E0,
    Z = 0xFF5555,
    T = 0xAAAA00
}

-- ==========================================
-- HELPERS
-- ==========================================

local function loadUsers()
    local h = fs.open("/etc/passwd.lua", "r")
    if h then
        local d = fs.read(h, math.huge)
        fs.close(h)
        if d then
            local f = load(d, "passwd", "t", {})
            if f then
                local bOk, db = pcall(f)
                if bOk and type(db) == "table" then
                    for user, info in pairs(db) do
                        tUidMap[info.uid] = user
                    end
                end
            end
        end
    end
end

local function fmtTime(sec)
    local m = math.floor(sec / 60)
    local s = math.floor(sec % 60)
    local h = math.floor((sec * 100) % 100)
    return string.format("%2d:%02d.%02d", m, s, h)
end

local function drawHtopMeter(x, y, w, label, pct, valStr, color)
    ctx:text(x, y, string.format("%-3s[", label), ctx:c("fg"), ctx:c("bg"))
    local barW = w - 12 - #valStr
    local nUsed = math.floor((pct / 100) * barW)
    
    if nUsed > 0 then
        ctx:text(x + 4, y, string.rep("|", nUsed), color, ctx:c("bg"))
    end
    ctx:text(x + 4 + nUsed, y, string.rep(" ", barW - nUsed), ctx:c("dim"), ctx:c("bg"))
    
    ctx:text(x + 4 + barW, y, string.format("%5.1f%% %s]", pct, valStr), ctx:c("fg"), ctx:c("bg"))
end

-- ==========================================
-- DATA GATHERING & SORTING
-- ==========================================

local function refreshData()
    local nNow = computer.uptime()
    local nDeltaT = nNow - nPrevUptime
    
    local tProcs1 = syscall("process_list") or {}
    local tMemInfo = syscall("mem_info") or {}
    tMem = tMemInfo

    local tMap = {}
    for _, p in ipairs(tMemInfo.tProcesses or {}) do tMap[p.pid] = p end

    tList = {}
    nTotalCpu = 0
    local nActiveTasks = 0
    local nRunningTasks = 0

    for _, p1 in ipairs(tProcs1) do
        local p2 = tMap[p1.pid] or {}
        local p = {
            pid     = p1.pid,
            parent  = p1.parent or 0,
            ring    = p1.ring or 3,
            uid     = p1.uid or 1000,
            user    = tUidMap[p1.uid] or tostring(p1.uid),
            status  = p1.status or "?",
            stateC  = tStatusChar[p1.status] or "?",
            image   = p1.image or "?",
            handles = p2.handles or 0,
            threads = p2.threads or 0,
            modules = p2.modules or 0,
            cpu     = p2.cpu or 0,
            memKB   = p2.memKB or 0
        }
        
        -- Approximate Per-Process Memory footprint in KB
        p.memKB = (p.modules * 45) + (p.handles * 4) + (p.threads * 10) + 20
        p.memPct = tMemInfo.nTotal and tMemInfo.nTotal > 0 and ((p.memKB * 1024) / tMemInfo.nTotal * 100) or 0
        
        local prevC = tPrevCpu[p.pid] or p.cpu
        p.cpuPct = (nDeltaT > 0) and ((p.cpu - prevC) / nDeltaT * 100) or 0
        if p.cpuPct < 0 then p.cpuPct = 0 end
        
        tPrevCpu[p.pid] = p.cpu
        nTotalCpu = nTotalCpu + p.cpuPct
        
        nActiveTasks = nActiveTasks + 1
        if p.status == "running" then nRunningTasks = nRunningTasks + 1 end
        
        -- Filter logic
        if sFilter == "" or p.image:lower():find(sFilter:lower(), 1, true) or p.user:lower():find(sFilter:lower(), 1, true) then
            tList[#tList+1] = p
        end
    end
    nPrevUptime = nNow

    -- Update Load Average (Exponential Moving Average)
    if nDeltaT > 0 then
        local exp1  = math.exp(-nDeltaT / 60)
        local exp5  = math.exp(-nDeltaT / 300)
        local exp15 = math.exp(-nDeltaT / 900)
        nLoad1  = nLoad1  * exp1  + nRunningTasks * (1 - exp1)
        nLoad5  = nLoad5  * exp5  + nRunningTasks * (1 - exp5)
        nLoad15 = nLoad15 * exp15 + nRunningTasks * (1 - exp15)
    end

    -- Base sort function (Safe native table.sort!)
    local function sortFunc(a, b)
        local va, vb
        if sSortCol == "cpu" then va, vb = a.cpuPct, b.cpuPct
        elseif sSortCol == "pid" then va, vb = a.pid, b.pid
        elseif sSortCol == "mem" then va, vb = a.memKB, b.memKB
        elseif sSortCol == "time" then va, vb = a.cpu, b.cpu
        elseif sSortCol == "user" then va, vb = a.user, b.user
        else va, vb = a.pid, b.pid end

        if va == vb then return a.pid < b.pid end
        if bSortDesc then return va > vb else return va < vb end
    end

    tSortedList = {}
    tTreePrefixes = {}

    if bTreeMode and sFilter == "" then
        -- Build Tree
        local tChildren = {}
        local tByPid = {}
        for _, p in ipairs(tList) do
            tByPid[p.pid] = p
            tChildren[p.parent] = tChildren[p.parent] or {}
            table.insert(tChildren[p.parent], p)
        end

        local function buildTree(parentId, prefix)
            local kids = tChildren[parentId]
            if not kids then return end
            table.sort(kids, sortFunc)
            
            for i, k in ipairs(kids) do
                local isLast = (i == #kids)
                local branch = isLast and "`-- " or "|-- "
                tTreePrefixes[k.pid] = prefix .. branch
                table.insert(tSortedList, k)
                
                local ext = isLast and "    " or "|   "
                buildTree(k.pid, prefix .. ext)
            end
        end

        -- Find root nodes (parents not in the list)
        local tRoots = {}
        for _, p in ipairs(tList) do
            if not tByPid[p.parent] then table.insert(tRoots, p) end
        end
        table.sort(tRoots, sortFunc)

        for _, r in ipairs(tRoots) do
            tTreePrefixes[r.pid] = ""
            table.insert(tSortedList, r)
            buildTree(r.pid, "")
        end
    else
        -- Flat List
        for _, p in ipairs(tList) do table.insert(tSortedList, p) end
        table.sort(tSortedList, sortFunc)
    end
end

-- ==========================================
-- INIT
-- ==========================================

loadUsers()
refreshData()

-- ==========================================
-- MAIN UI LOOP
-- ==========================================

while bRunning do
    local nNow = computer.uptime()
    if nNow - nLastRefresh >= REFRESH_RATE then
        refreshData()
        nLastRefresh = nNow
    end

    ctx:beginFrame()
    ctx:clear(ctx:c("bg"))

    -- ── HEADER (Row 1-3) ──
    local nHalfW = math.floor(W / 2)
    
    -- Left Col: Meters
    drawHtopMeter(1, 1, nHalfW - 2, "CPU", math.min(100, nTotalCpu), "", ctx:c("cpu_bar"))
    local sMemStr = string.format("%dK/%dK", math.floor(tMem.nUsed/1024), math.floor(tMem.nTotal/1024))
    drawHtopMeter(1, 2, nHalfW - 2, "MEM", tMem.nUsedPct, sMemStr, ctx:c("mem_bar"))
    drawHtopMeter(1, 3, nHalfW - 2, "SWP", 0, "0K/0K", 0xFF5555)

    -- Right Col: Stats
    ctx:text(nHalfW, 1, string.format("Tasks: %d, %d thr; %d running", #tList, tMem.nProcesses or #tList, math.ceil(nLoad1)), ctx:c("fg"))
    ctx:text(nHalfW, 2, string.format("Load average: %.2f %.2f %.2f", nLoad1, nLoad5, nLoad15), ctx:c("fg"))
    -- ctx:text(nHalfW, 3, string.format("Uptime: %02d:%02d:%02d", math.floor(nNow/3600), math.floor(nNow/60)%60, nNow%60), ctx:c("fg"))

    -- ── COLUMNS (Row 4) ──
    local yList = 5
    local sHeader = string.format(" %-5s %-8s %3s %3s %4s %1s %5s %8s %s",
        "PID", "USER", "PRI", "NI", "MEM", "S", "CPU%", "TIME+", "Command")
    
    ctx:fill(1, yList, W, 1, " ", ctx:c("bar_fg"), ctx:c("bar_bg"))
    ctx:text(1, yList, sHeader, ctx:c("bar_fg"), ctx:c("bar_bg"))

    -- ── PROCESS LIST ──
    local listH = H - yList - 1
    if bSearchMode then listH = listH - 1 end -- leave room for search bar

    local first, last, sel, cw, bAct = ctx:beginScroll("plist", 1, yList+1, W, listH, #tSortedList, 1)
    for i = first, last do
        local p = tSortedList[i]
        local ry = yList + 1 + (i - first)
        local bSel = (i == sel)
        
        local bg = bSel and ctx:c("sel_bg") or ctx:c("bg")
        local fg = bSel and ctx:c("sel_fg") or ctx:c("fg")

        -- Tree prefix
        local sPrefix = tTreePrefixes[p.pid] or ""
        local nAvailCmdW = cw - 54 - #sPrefix
        if nAvailCmdW < 1 then nAvailCmdW = 1 end
        
        local sCmdDisplay = sPrefix .. p.image:sub(1, nAvailCmdW)
        
        local sMemDisp = tostring(math.floor(p.memKB)) .. "K"
        if #sMemDisp > 5 then
            sMemDisp = tostring(math.floor(p.memKB / 1024)) .. "M"
        end

        local sData = string.format(" %-5d %-8s %4s %3d %5s %5.1f %1s %5.1f %8s ",
            p.pid, p.user:sub(1,8), p.ring, p.threads, math.floor(p.memKB),
            p.stateC, p.cpuPct, fmtTime(p.cpu))

        ctx:textPad(1, ry, cw, sData, fg, bg)
        
        -- Draw status char in color if not selected
        if not bSel then
            ctx:text(38, ry, p.stateC, tStatusColor[p.stateC] or fg, bg)
        end

        -- Draw command
        local cmdCol = bSel and fg or ctx:c("title")
        local treeCol = bSel and fg or ctx:c("tree_line")
        
        ctx:text(55, ry, sPrefix, treeCol, bg)
        ctx:text(55 + #sPrefix, ry, p.image:sub(1, nAvailCmdW), cmdCol, bg)
    end
    ctx:endScroll()

    -- ── FOOTER ──
    if bSearchMode then
        local sNewFilter, bChanged, bSubmit = ctx:textInput("filter", 1, H, W, sFilter, ctx:c("input_fg"), ctx:c("input_bg"), ctx:c("input_afg"), ctx:c("input_abg"))
        if bChanged then
            sFilter = sNewFilter
            refreshData()
        end
        if bSubmit or ctx:key() == "\27" then
            bSearchMode = false
        end
    else
        ctx:fill(1, H, W, 1, " ", ctx:c("fg"), ctx:c("bg"))
        local fKeys = {
            {"F1","Help"}, {"F2","Setup"}, {"F3","Search"}, {"F4","Filter"},
            {"F5","Tree"}, {"F6","SortBy"}, {"F7","Nice-"}, {"F8","Nice+"},
            {"F9","Kill"}, {"F10","Quit"}
        }
        local fx = 1
        for _, kDef in ipairs(fKeys) do
            local btnTxt = kDef[1] .. kDef[2] .. " "
            if ctx:button("f_"..kDef[1], fx, H, btnTxt, ctx:c("fg"), ctx:c("bg"), ctx:c("bar_fg"), ctx:c("bar_bg")) then
                -- trigger actions below
            end
            ctx:text(fx, H, kDef[1], ctx:c("title"), ctx:c("bg")) -- Highlight the F-key
            fx = fx + #btnTxt
        end
    end

    -- ── INPUT & MODALS ──
    local k = ctx:key()

    if not ctx:hasModal() and not bSearchMode then
        if k == "q" or k == "\27[21~" or k == "\3" then -- q, F10, Ctrl+C
            bRunning = false
        elseif k == "\27[15~" or k == "t" then -- F5 / t
            bTreeMode = not bTreeMode
            refreshData()
        elseif k == "\27[17~" or k == "s" then -- F6 / s
            ctx:commandPalette("sort_pal", {
                {id="cpu", label="CPU%"},
                {id="mem", label="Memory"},
                {id="pid", label="PID"},
                {id="time", label="Time+"},
                {id="user", label="User"}
            })
        elseif k == "/" or k == "\27[13~" or k == "\27[14~" then -- /, F3, F4
            bSearchMode = true
        elseif (k == "k" or k == "\27[20~" or bAct) and tSortedList[sel] then -- k, F9, Enter
            local tp = tSortedList[sel]
            if tp.pid <= 1 then
                ctx:alert("kill_err", "Permission Denied", "Cannot kill Kernel (PID 0) or PM (PID 1)!", "OK")
            else
                ctx:commandPalette("kill_pal", {
                    {id="15", label="15 SIGTERM (Terminate)"},
                    {id="9",  label="9 SIGKILL (Force Kill)"},
                    {id="19", label="19 SIGSTOP (Pause)"},
                    {id="18", label="18 SIGCONT (Resume)"}
                })
            end
        end
    else
        -- Check Modal Results
        local rSort = ctx:modalResult("sort_pal")
        if rSort then
            sSortCol = rSort
            refreshData()
        end

        local rKill = ctx:modalResult("kill_pal")
        if rKill then
            local tp = tSortedList[sel]
            if tp then
                local bOk, sErr = syscall("process_kill", tp.pid, tonumber(rKill))
                if bOk then ctx:toastSuccess("Sent signal " .. rKill .. " to PID " .. tp.pid)
                else ctx:toastError(sErr or "Kill failed") end
            end
        end
        
        ctx:modalResult("kill_err")
    end

    ctx:endFrame()
    syscall("process_yield")
end

ctx:destroy()