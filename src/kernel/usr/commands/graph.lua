-- /usr/commands/xe_graphs_demo.lua

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
        "XE_ui_graph_canvas",
        "XE_ui_graph_api",
        "XE_ui_toast",
    },
})
if not ctx then print("xe: no context"); return end

local W, H = ctx.W, ctx.H
local running = true
local frames  = 0
local MAX_HISTORY = 120

-- O(1) push ring buffers — no table.remove stutter
local tMemHistory = xe.timeSeries(MAX_HISTORY)
local tCpuFake    = xe.timeSeries(MAX_HISTORY)
local tCpuFake2   = xe.timeSeries(MAX_HISTORY)
local tLatency    = xe.timeSeries(MAX_HISTORY)

local nCpuPhase = 0

while running do
    ctx:beginFrame()
    ctx:clear(ctx:c("bg"))
    frames = frames + 1

    -- ---- Update data (O(1) per push, no shifting) ----
    local nFree = computer.freeMemory()
    local nTotal = computer.totalMemory()
    local nUsedPct = math.floor((nTotal - nFree) / nTotal * 100)
    tMemHistory:push(nUsedPct)

    nCpuPhase = nCpuPhase + 0.15
    local nCpuVal = 30 + 25 * math.sin(nCpuPhase) + math.random(-5, 5)
    nCpuVal = math.max(0, math.min(100, nCpuVal))
    tCpuFake:push(nCpuVal)
    tCpuFake2:push(math.max(0, math.min(100, nCpuVal * 0.6 + math.random(-8, 8))))

    tLatency:push(math.max(0, math.min(1,
        0.3 + 0.3 * math.sin(nCpuPhase * 0.7) + math.random() * 0.2)))

    -- ---- Title bar ----
    ctx:fill(1, 1, W, 1, " ", ctx:c("bar_fg"), ctx:c("bar_bg"))
    ctx:text(2, 1, "XE Graph Demo", ctx:c("accent"), ctx:c("bar_bg"))
    ctx:textf(W - 22, 1, ctx:c("dim"), ctx:c("bar_bg"),
              "F:%d Pts:%d Q:Quit", frames, tMemHistory:len())

    local cw = math.floor(W / 2) - 2

    -- ---- Memory line graph ----
    ctx:text(2, 3, "Memory Usage (%)", ctx:c("accent"))
    ctx:lineGraph("mem_line", 2, 4, cw, 8, tMemHistory, {
        color = 0x55FF55, bgColor = 0x0A0A1A,
        gridColor = 0x1A1A3A, minY = 0, maxY = 100,
        filled = true, fillColor = 0x003311,
    })

    -- ---- CPU multi-line ----
    ctx:text(2, 13, "CPU Cores (simulated)", ctx:c("accent"))
    ctx:multiLineGraph("cpu_multi", 2, 14, cw, 8, {
        {data = tCpuFake,  color = 0xFF5555},
        {data = tCpuFake2, color = 0x5555FF},
    }, {
        bgColor = 0x0A0A1A, gridColor = 0x1A1A3A,
        minY = 0, maxY = 100,
    })
    ctx:text(2, 22, "\x07", 0xFF5555)
    ctx:text(4, 22, "Core 0", ctx:c("dim"))
    ctx:text(12, 22, "\x07", 0x5555FF)
    ctx:text(14, 22, "Core 1", ctx:c("dim"))

    -- ---- Right column ----
    local rx = math.floor(W / 2) + 1

    ctx:text(rx, 3, "Memory Sparkline:", ctx:c("accent"))
    ctx:sparkline(rx, 4, cw, tMemHistory, 0x55FF55, 0x0A0A1A)

    ctx:text(rx, 6, "CPU Sparkline:", ctx:c("accent"))
    ctx:sparkline(rx, 7, cw, tCpuFake, 0xFF5555, 0x0A0A1A)

    ctx:text(rx, 9, "Latency Heatmap:", ctx:c("accent"))
    ctx:heatRow(rx, 10, cw, tLatency)

    -- ---- Bar chart ----
    ctx:text(rx, 12, "Processes by Ring:", ctx:c("accent"))
    local tProcs = syscall("process_list") or {}
    local tRC = {0, 0, 0, 0, 0}
    for _, p in ipairs(tProcs) do
        local r = p.ring
        if r == 0 then tRC[1] = tRC[1]+1
        elseif r == 1 then tRC[2] = tRC[2]+1
        elseif r == 2 then tRC[3] = tRC[3]+1
        elseif r == 2.5 then tRC[4] = tRC[4]+1
        else tRC[5] = tRC[5]+1 end
    end
    ctx:barChart("ring_bars", rx, 13, cw, 5, {
        {value=tRC[1], color=0xFF3333},
        {value=tRC[2], color=0xFF8833},
        {value=tRC[3], color=0xFFFF33},
        {value=tRC[4], color=0x33FF33},
        {value=tRC[5], color=0x3333FF},
    }, {bgColor = 0x0A0A1A, spacing = 1})
    ctx:textf(rx, 19, ctx:c("dim"), nil,
        "R0:%d R1:%d R2:%d R2.5:%d R3:%d",
        tRC[1], tRC[2], tRC[3], tRC[4], tRC[5])

    -- ---- Canvas demo ----
    ctx:text(rx, 21, "Pixel Canvas:", ctx:c("accent"))
    local cv = ctx:canvas("raw_demo", rx, 22, 20, 2, 0x0A0A1A)
    cv:clear()
    local cx2 = 10 + math.floor(9 * math.cos(frames * 0.1))
    local cy2 = math.floor(1.5 + 1.5 * math.sin(frames * 0.1))
    cv:line(10, 2, cx2, cy2, 0xFFFF55)
    cv:rect(0, 0, 20, 4, 0x555555)
    cv:flush()

    -- ---- Status ----
    ctx:fill(1, H, W, 1, " ", ctx:c("bar_fg"), ctx:c("bar_bg"))
    ctx:textf(2, H, ctx:c("dim"), ctx:c("bar_bg"),
        "Mem:%d%% Data:%d/%d %d procs",
        nUsedPct, tMemHistory:len(), MAX_HISTORY, #tProcs)

    -- Milestone toasts
    local nPts = tMemHistory:len()
    if nPts == 50 then ctx:toastInfo("50 data points collected") end
    if nPts == 100 then ctx:toastSuccess("100 points — no stutter!") end

    local k = ctx:key()
    if k == "q" or k == "\3" then running = false end

    ctx:endFrame()
end

ctx:destroy()