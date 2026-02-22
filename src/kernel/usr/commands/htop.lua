--
-- /usr/commands/htop.lua
-- AxisOS Interactive Process Viewer
--

local xe       = require("xe")
local computer = require("computer")

local ctx = xe.createContext({
    theme = xe.THEMES.dark,
    extensions = {
        "XE_ui_shadow_buffering_render_batch",
        "XE_ui_diff_render_feature",
        "XE_ui_alt_screen_query",
        "XE_ui_deferred_clear",
        "XE_ui_imgui_navigation",
        "XE_ui_dirty_row_tracking",
        "XE_ui_run_length_grouping",
        "XE_ui_graph_api",
        "XE_ui_toast",
        "XE_ui_modal_prebuilt",
    },
})
if not ctx then print("htop: cannot open display"); return end

local W, H = ctx.W, ctx.H
local running = true

-- =============================================
-- STATE
-- =============================================

local MAX_HIST = math.max(10, W - 8)
local tCpuHist = xe.timeSeries(MAX_HIST)
local tMemHist = xe.timeSeries(MAX_HIST)

local tSortKeys  = {"pid", "cpu", "ring", "status", "image"}
local tSortNames = {"PID", "CPU", "RING", "STATUS", "IMAGE"}
local nSortIdx   = 2
local sSortKey   = "cpu"
local bTreeMode  = false
local sFilter    = ""
local bFiltering = false
local nKillTarget = nil

-- =============================================
-- COLORS
-- =============================================

local function ringColor(r)
    if r == 0   then return 0xFF3333 end  -- kernel
    if r == 1   then return 0xFF8833 end  -- system
    if r == 2   then return 0xFFCC33 end  -- driver
    if r == 2.5 then return 0x33FF88 end  -- elevated
    return 0xCCCCCC                        -- user
end

local function statusColor(s)
    if s == "running"  then return 0x55FF55 end
    if s == "ready"    then return 0xFFFFFF end
    if s == "sleeping" then return 0x777777 end
    if s == "stopped"  then return 0xFF5555 end
    return 0x444444
end

local tRingLabels = {
    [0] = "R0:KRN", [1] = "R1:SYS", [2] = "R2:DRV",
    [2.5] = "R2+", [3] = "R3:USR",
}

-- =============================================
-- SORT
-- =============================================

local tSortFn = {
    pid    = function(a, b) return a.pid < b.pid end,
    cpu    = function(a, b) return a.cpu > b.cpu end,
    ring   = function(a, b)
        if a.ring ~= b.ring then return a.ring < b.ring end
        return a.pid < b.pid
    end,
    status = function(a, b)
        if a.status ~= b.status then return a.status < b.status end
        return a.pid < b.pid
    end,
    image  = function(a, b) return a.image < b.image end,
}

-- =============================================
-- TREE BUILDER
-- =============================================

local function buildTree(tProcs)
    local tByPid = {}
    local tKids  = {}
    for _, p in ipairs(tProcs) do
        tByPid[p.pid] = p
        local nPar = p.parent or 0
        if not tKids[nPar] then tKids[nPar] = {} end
        tKids[nPar][#tKids[nPar] + 1] = p
    end

    -- Sort children by PID within each parent
    for _, tList in pairs(tKids) do
        table.sort(tList, function(a, b) return a.pid < b.pid end)
    end

    local tOut = {}
    local tVisited = {}

    local function walk(nPid, nDepth, bLast)
        if tVisited[nPid] then return end
        tVisited[nPid] = true
        local p = tByPid[nPid]
        if p then
            p._depth = nDepth
            p._last  = bLast
            tOut[#tOut + 1] = p
        end
        local kids = tKids[nPid]
        if kids then
            for i, k in ipairs(kids) do
                walk(k.pid, nDepth + 1, i == #kids)
            end
        end
    end

    -- Find roots: processes whose parent isn't in the list or is themselves
    for _, p in ipairs(tProcs) do
        if not tByPid[p.parent] or p.parent == p.pid then
            walk(p.pid, 0, true)
        end
    end
    return tOut
end

-- =============================================
-- TREE PREFIX STRING
-- =============================================

local function treePrefix(p)
    if not p._depth or p._depth == 0 then return "" end
    local sIndent = string.rep("  ", math.max(0, p._depth - 1))
    local sBranch = p._last and "\\-" or "|-"
    return sIndent .. sBranch
end

-- =============================================
-- MAIN LOOP
-- =============================================

while running do
    ctx:beginFrame()
    ctx:clear(ctx:c("bg"))

    -- ======== COLLECT ========
    local tRawProcs   = syscall("process_list") or {}
    local tSchedStats = syscall("sched_get_stats") or {}
    local tPgStats    = syscall("patchguard_status") or {}

    local nFree  = computer.freeMemory()
    local nTotal = computer.totalMemory()
    local nUsed  = nTotal - nFree
    local nMemPct = math.floor(nUsed / nTotal * 100)
    local nUp    = computer.uptime()

    -- Enrich processes with CPU stats
    local tProcs = {}
    local nTotalCpu = 0
    for _, p in ipairs(tRawProcs) do
        local tC = syscall("process_cpu_stats", p.pid) or {}
        local nCpu = tC.nCpuTime or 0
        nTotalCpu = nTotalCpu + nCpu
        tProcs[#tProcs + 1] = {
            pid       = p.pid,
            parent    = p.parent or 0,
            ring      = p.ring,
            status    = p.status,
            uid       = p.uid or 0,
            image     = p.image or "?",
            cpu       = nCpu,
            preempt   = tC.nPreemptCount or 0,
            maxSlice  = (tC.nMaxSlice or 0) * 1000,
            wdStrikes = tC.nWatchdogStrikes or 0,
            _depth    = 0,
            _last     = true,
        }
    end

    -- Approximate load: ratio of preemptions to total resumes
    local nLoadPct = 0
    if (tSchedStats.nTotalResumes or 0) > 0 then
        nLoadPct = math.min(100, math.floor(
            (tSchedStats.nPreemptions or 0) /
            (tSchedStats.nTotalResumes or 1) * 100))
    end
    tCpuHist:push(nLoadPct)
    tMemHist:push(nMemPct)

    -- Filter
    local tFiltered = {}
    local sLow = sFilter:lower()
    for _, p in ipairs(tProcs) do
        if #sFilter == 0
           or tostring(p.pid):find(sFilter, 1, true)
           or p.image:lower():find(sLow, 1, true)
           or p.status:find(sLow, 1, true) then
            tFiltered[#tFiltered + 1] = p
        end
    end

    -- Sort or tree
    local tDisplay
    if bTreeMode then
        tDisplay = buildTree(tFiltered)
    else
        table.sort(tFiltered, tSortFn[sSortKey] or tSortFn.pid)
        tDisplay = tFiltered
    end

    -- ======== HEADER ========
    local hy = 1

    -- Title bar
    ctx:fill(1, hy, W, 1, " ", ctx:c("bar_fg"), ctx:c("bar_bg"))
    ctx:text(2, hy, "htop", 0xFFFF55, ctx:c("bar_bg"))
    ctx:textf(8, hy, ctx:c("bar_fg"), ctx:c("bar_bg"),
        "- AxisOS Process Viewer")

    -- PG indicator
    local sPgLabel = tPgStats.bArmed and "PG:ON" or "PG:--"
    local nPgColor = tPgStats.bArmed and 0x55FF55 or 0x888888
    ctx:text(W - 28, hy, sPgLabel, nPgColor, ctx:c("bar_bg"))

    ctx:textf(W - 22, hy, ctx:c("dim"), ctx:c("bar_bg"),
        "Up %d:%02d:%02d  P:%d",
        math.floor(nUp / 3600),
        math.floor((nUp % 3600) / 60),
        math.floor(nUp % 60),
        #tProcs)
    hy = hy + 1

    -- CPU line
    ctx:text(2, hy, "CPU", ctx:c("accent"))
    ctx:text(6, hy, "[", ctx:c("dim"))
    local nBarW = math.min(24, math.floor(W * 0.3))
    ctx:progress(7, hy, nBarW, nLoadPct, nil, 0x111122, nil,
        nLoadPct > 80 and 0xAA2222 or 0x22AA44)
    ctx:text(7 + nBarW, hy, "]", ctx:c("dim"))
    ctx:textf(9 + nBarW, hy, ctx:c("fg"), nil, "%3d%%", nLoadPct)

    local nStatsX = 14 + nBarW
    ctx:textf(nStatsX, hy, ctx:c("dim"), nil,
        "sched: %dR %dP %dW %dK",
        tSchedStats.nTotalResumes or 0,
        tSchedStats.nPreemptions or 0,
        tSchedStats.nWatchdogWarnings or 0,
        tSchedStats.nWatchdogKills or 0)
    hy = hy + 1

    -- Memory line
    ctx:text(2, hy, "Mem", ctx:c("accent"))
    ctx:text(6, hy, "[", ctx:c("dim"))
    ctx:progress(7, hy, nBarW, nMemPct, nil, 0x111122, nil,
        nMemPct > 85 and 0xAA2222 or 0x2244AA)
    ctx:text(7 + nBarW, hy, "]", ctx:c("dim"))

    local nMemFg = nMemPct > 85 and 0xFF5555 or ctx:c("fg")
    ctx:textf(9 + nBarW, hy, nMemFg, nil, "%3d%%", nMemPct)
    ctx:textf(nStatsX, hy, ctx:c("dim"), nil,
        "%.0fK / %.0fK  (%.0fK free)",
        nUsed / 1024, nTotal / 1024, nFree / 1024)

    if nFree < 32768 then
        ctx:text(W - 10, hy, " LOW MEM ", 0xFFFFFF, 0xAA0000)
    end
    hy = hy + 1

    -- Sparklines
    local nSpkX = 6
    local nSpkW = W - nSpkX - 1
    ctx:text(2, hy, "cpu", 0x55AA55)
    ctx:sparkline(nSpkX, hy, nSpkW, tCpuHist, 0x55FF55, 0x0A0A1A)
    hy = hy + 1
    ctx:text(2, hy, "mem", 0x5555AA)
    ctx:sparkline(nSpkX, hy, nSpkW, tMemHist, 0x5555FF, 0x0A0A1A)
    hy = hy + 1

    -- Ring breakdown (compact)
    local tRC = {}
    for _, p in ipairs(tProcs) do
        tRC[p.ring] = (tRC[p.ring] or 0) + 1
    end
    local tRingParts = {}
    for _, r in ipairs({0, 1, 2, 2.5, 3}) do
        if tRC[r] then
            tRingParts[#tRingParts + 1] = {
                label = (tRingLabels[r] or "R?") .. ":" .. tRC[r],
                color = ringColor(r),
            }
        end
    end
    local rx = 2
    for _, rp in ipairs(tRingParts) do
        ctx:text(rx, hy, rp.label, rp.color)
        rx = rx + #rp.label + 2
    end

    -- PatchGuard stats on same line
    if tPgStats.bAvailable then
        local sPg = string.format("PG: %d chk %d viol",
            tPgStats.nChecksPerformed or 0,
            tPgStats.nViolations or 0)
        ctx:text(W - #sPg - 1, hy, sPg,
            (tPgStats.nViolations or 0) > 0 and 0xFF5555 or 0x555555)
    end
    hy = hy + 1

    -- Separator
    ctx:separator(1, hy, W, ctx:c("border"))
    hy = hy + 1

    -- ======== COLUMN HEADER ========
    -- Columns:    PID  PPID RING STATUS   CPU(s)  PRE  WD  MS   IMAGE
    -- Positions:  1    7    13   19       28      37   43  47   52
    local COL = {pid=2, ppid=7, ring=13, status=19, cpu=28, pre=37, wd=43, ms=47, img=52}

    ctx:fill(1, hy, W, 1, " ", ctx:c("dim"), 0x111133)
    ctx:text(COL.pid,    hy, "PID",    ctx:c("dim"), 0x111133)
    ctx:text(COL.ppid,   hy, "PPID",   ctx:c("dim"), 0x111133)
    ctx:text(COL.ring,   hy, "RING",   ctx:c("dim"), 0x111133)
    ctx:text(COL.status, hy, "STATUS", ctx:c("dim"), 0x111133)
    ctx:text(COL.cpu,    hy, "CPU(s)",  ctx:c("dim"), 0x111133)
    ctx:text(COL.pre,    hy, "PRE",    ctx:c("dim"), 0x111133)
    ctx:text(COL.wd,     hy, "WD",     ctx:c("dim"), 0x111133)
    ctx:text(COL.ms,     hy, "MS",     ctx:c("dim"), 0x111133)
    ctx:text(COL.img,    hy, "IMAGE",  ctx:c("dim"), 0x111133)

    -- Highlight active sort column
    local tSortColMap = {pid=COL.pid, cpu=COL.cpu, ring=COL.ring,
                         status=COL.status, image=COL.img}
    local nSortHighlight = tSortColMap[sSortKey]
    if nSortHighlight then
        local sLabel = tSortNames[nSortIdx]
        ctx:text(nSortHighlight, hy, sLabel, 0xFFFF55, 0x111133)
        if sSortKey == "cpu" then
            ctx:text(nSortHighlight + #sLabel, hy, "v", 0xFFFF55, 0x111133)
        end
    end
    hy = hy + 1

    -- ======== PROCESS LIST ========
    local nListH = H - hy - 2
    if nListH < 3 then nListH = 3 end

    local first, last, sel, scW, bAct = ctx:beginScroll(
        "proclist", 1, hy, W, nListH, #tDisplay)

    for i = first, last do
        local p = tDisplay[i]
        local ry = hy + (i - first)
        local bSel = (i == sel)

        local sFg = ctx:c("fg")
        local sBg = ctx:c("bg")
        if bSel then sFg = ctx:c("sel_fg"); sBg = ctx:c("sel_bg") end

        -- Background fill
        ctx:fill(1, ry, scW, 1, " ", sFg, sBg)

        -- PID
        ctx:textf(COL.pid, ry, sFg, sBg, "%-5d", p.pid)

        -- PPID
        ctx:textf(COL.ppid, ry, bSel and sFg or ctx:c("dim"), sBg,
            "%-5d", p.parent)

        -- Ring (colored)
        local nRFg = bSel and sFg or ringColor(p.ring)
        ctx:textf(COL.ring, ry, nRFg, sBg, "%-5s", tostring(p.ring))

        -- Status (colored)
        local nSFg = bSel and sFg or statusColor(p.status)
        ctx:textf(COL.status, ry, nSFg, sBg, "%-8s", p.status)

        -- CPU time
        local nCpuFg = sFg
        if not bSel and p.cpu > 1.0 then nCpuFg = 0xFFAA55 end
        if not bSel and p.cpu > 5.0 then nCpuFg = 0xFF5555 end
        ctx:textf(COL.cpu, ry, nCpuFg, sBg, "%7.3f", p.cpu)

        -- Preemptions
        ctx:textf(COL.pre, ry, bSel and sFg or ctx:c("dim"), sBg,
            "%5d", p.preempt)

        -- Watchdog strikes
        local nWdFg = sFg
        if not bSel and p.wdStrikes > 0 then nWdFg = 0xFF5555 end
        ctx:textf(COL.wd, ry, nWdFg, sBg, "%2d", p.wdStrikes)

        -- Max slice (ms)
        ctx:textf(COL.ms, ry, bSel and sFg or ctx:c("dim"), sBg,
            "%4.0f", p.maxSlice)

        -- Image (with tree prefix)
        local sPrefix = bTreeMode and treePrefix(p) or ""
        local sImg = sPrefix .. p.image
        local nImgMax = scW - COL.img
        if nImgMax < 4 then nImgMax = 4 end
        if #sImg > nImgMax then
            sImg = ".." .. sImg:sub(-(nImgMax - 2))
        end
        ctx:text(COL.img, ry, sImg, sFg, sBg)
    end
    ctx:endScroll()

    -- ======== KILL CONFIRMATION ========
    if nKillTarget then
        local sTgtName = "?"
        for _, p in ipairs(tDisplay) do
            if p.pid == nKillTarget then sTgtName = p.image; break end
        end
        local sMsg = string.format(
            "Send SIGTERM to PID %d (%s)?", nKillTarget, sTgtName)
        local r = ctx:confirm("kill_dlg", "Kill Process", sMsg,
            "Kill", "Cancel")
        if r == true then
            local bOk, sErr = syscall("process_kill", nKillTarget)
            if bOk then
                ctx:toastSuccess("Killed PID " .. nKillTarget)
            else
                ctx:toastError(tostring(sErr))
            end
            nKillTarget = nil
        elseif r == false then
            nKillTarget = nil
        end
    end

    -- ======== STATUS BAR ========
    if bFiltering then
        ctx:fill(1, H - 1, W, 1, " ", ctx:c("input_fg"), ctx:c("input_bg"))
        ctx:text(2, H - 1, "Filter: /", ctx:c("accent"), ctx:c("input_bg"))
        local sNew, bCh, bSub = ctx:textInput(
            "filter_input", 12, H - 1, W - 14, sFilter)
        if bCh then sFilter = sNew end
        if bSub then bFiltering = false end
    else
        ctx:fill(1, H - 1, W, 1, " ", ctx:c("dim"), 0x0D0D22)
        ctx:textf(2, H - 1, ctx:c("dim"), 0x0D0D22,
            "%d process(es)%s  sort: %s%s  cpu: %.1fs",
            #tDisplay,
            #sFilter > 0 and (" [/" .. sFilter .. "]") or "",
            tSortNames[nSortIdx],
            bTreeMode and "  [TREE]" or "",
            nTotalCpu)
    end

    -- ======== KEY HINTS BAR ========
    ctx:fill(1, H, W, 1, " ", ctx:c("bar_fg"), ctx:c("bar_bg"))
    local tHints = {
        {"t", "Tree"}, {">", "Sort"}, {"k", "Kill"},
        {"/", "Filter"}, {"q", "Quit"},
    }
    local kx = 1
    for _, h in ipairs(tHints) do
        ctx:text(kx + 1, H, h[1], 0x000000, 0xAAAAAA)
        kx = kx + #h[1] + 1
        ctx:text(kx + 1, H, h[2], ctx:c("bar_fg"), ctx:c("bar_bg"))
        kx = kx + #h[2] + 2
    end

    -- ======== INPUT ========
    local k = ctx:key()
    if k and not bFiltering and not nKillTarget then
        if k == "q" or k == "\3" then
            running = false

        elseif k == "t" or k == "\27[15~" then  -- t or F5
            bTreeMode = not bTreeMode
            ctx:toastInfo(bTreeMode and "Tree view" or "Flat view")

        elseif k == ">" or k == "<" then
            if k == ">" then
                nSortIdx = (nSortIdx % #tSortKeys) + 1
            else
                nSortIdx = nSortIdx - 1
                if nSortIdx < 1 then nSortIdx = #tSortKeys end
            end
            sSortKey = tSortKeys[nSortIdx]
            ctx:toastInfo("Sort: " .. tSortNames[nSortIdx])

        elseif k == "k" then
            local st = ctx._scrollState["proclist"]
            local nSelIdx = st and st.sel or 1
            if tDisplay[nSelIdx] then
                local nTarget = tDisplay[nSelIdx].pid
                if nTarget <= 1 then
                    ctx:toastError("Cannot kill kernel process")
                else
                    nKillTarget = nTarget
                end
            end

        elseif k == "/" then
            bFiltering = true

        elseif k == "\27" then
            if #sFilter > 0 then
                sFilter = ""
                ctx:toastInfo("Filter cleared")
            end
        end

    elseif k and bFiltering then
        if k == "\27" then
            bFiltering = false
            sFilter = ""
        end
    end

    ctx:endFrame()
end

ctx:destroy()