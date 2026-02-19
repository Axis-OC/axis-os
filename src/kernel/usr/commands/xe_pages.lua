-- /usr/commands/xe_pages.lua
-- Demonstrates suspend/resume, pages, and GPU double buffer.

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
        "XE_ui_suspend_resume",
        "XE_ui_page_manager",
        "XE_ui_gpu_double_buffer",   -- flicker-free
        "XE_ui_gpu_page_snapshot",   -- instant page restore
    },
})
if not ctx then print("xe: no context"); return end

-- Create pages
ctx:createPage("dashboard")   -- active by default (first page)
ctx:createPage("processes")
ctx:createPage("memory")

local running = true
local tabs = {"dashboard", "processes", "memory"}
local tabLabels = {" F1:Dashboard ", " F2:Processes ", " F3:Memory "}

while running do
    -- ---- Input (works even if page logic is minimal) ----
    local bInput = ctx:beginFrame()
    local k = ctx:key()

    -- Global hotkeys (work on any page)
    if k == "\3" or k == "q" then running = false end
    if k == "\27[11~" then ctx:switchPage("dashboard") end  -- F1
    if k == "\27[12~" then ctx:switchPage("processes") end  -- F2
    if k == "\27[13~" then ctx:switchPage("memory")    end  -- F3

    -- ---- Render active page ----
    local W, H = ctx.W, ctx.H
    local pg = ctx:getActivePage()

    ctx:clear(ctx:c("bg"))

    -- Tab bar (shared across all pages)
    ctx:fill(1, 1, W, 1, " ", ctx:c("bar_fg"), ctx:c("bar_bg"))
    local tx = 1
    for i, id in ipairs(tabs) do
        local bActive = (id == pg)
        local fg = bActive and ctx:c("sel_fg") or ctx:c("bar_fg")
        local bg = bActive and ctx:c("sel_bg") or ctx:c("bar_bg")
        ctx:text(tx, 1, tabLabels[i], fg, bg)
        tx = tx + #tabLabels[i]
    end
    ctx:textf(W - 6, 1, ctx:c("dim"), ctx:c("bar_bg"), "Q:Quit")

    -- Page content
    if pg == "dashboard" then
        ctx:text(3, 4, "System Dashboard", ctx:c("accent"))
        ctx:separator(3, 5, 30)
        local up = computer.uptime()
        ctx:textf(3, 7, ctx:c("fg"), nil, "Uptime: %d:%02d:%02d",
            math.floor(up/3600), math.floor(up%3600/60), math.floor(up%60))
        ctx:textf(3, 8, ctx:c("fg"), nil, "Free:   %.1f KB",
            computer.freeMemory() / 1024)
        ctx:textf(3, 9, ctx:c("fg"), nil, "GPU Buf: %s",
            ctx._bGpuBuf and "Yes (double-buffered)" or "No")

        local tPages = ctx:listPages()
        ctx:text(3, 11, "Pages:", ctx:c("accent2"))
        for i, p in ipairs(tPages) do
            ctx:textf(5, 11 + i, p.active and ctx:c("ok") or ctx:c("dim"), nil,
                "%s %s%s", p.active and ">" or " ", p.id,
                p.hasSnapshot and " [snap]" or "")
        end

    elseif pg == "processes" then
        ctx:text(3, 4, "Process List", ctx:c("accent"))
        ctx:separator(3, 5, 40)
        local tProcs = syscall("process_list") or {}
        ctx:textf(3, 6, ctx:c("dim"), nil,
            "%-5s %-4s %-8s %s", "PID", "RING", "STATUS", "IMAGE")
        for i, p in ipairs(tProcs) do
            if 6 + i >= H - 2 then break end
            ctx:textf(3, 6 + i, ctx:c("fg"), nil,
                "%-5d %-4s %-8s %s",
                p.pid, tostring(p.ring), p.status,
                (p.image or "?"):sub(-30))
        end

    elseif pg == "memory" then
        ctx:text(3, 4, "Memory Info", ctx:c("accent"))
        ctx:separator(3, 5, 30)
        local nT = computer.totalMemory()
        local nF = computer.freeMemory()
        local pct = math.floor((nT - nF) / nT * 100)
        ctx:textf(3, 7, ctx:c("fg"), nil, "Total: %.1f KB", nT / 1024)
        ctx:textf(3, 8, ctx:c("fg"), nil, "Used:  %.1f KB (%d%%)",
            (nT - nF) / 1024, pct)
        ctx:textf(3, 9, ctx:c("fg"), nil, "Free:  %.1f KB", nF / 1024)
        ctx:progress(3, 11, 40, pct)
    end

    -- Status bar
    ctx:fill(1, H, W, 1, " ", ctx:c("bar_fg"), ctx:c("bar_bg"))
    ctx:textf(2, H, ctx:c("dim"), ctx:c("bar_bg"),
        "Page: %s | F1/F2/F3 switch | Q quit", pg)

    ctx:endFrame()
end

ctx:destroy()