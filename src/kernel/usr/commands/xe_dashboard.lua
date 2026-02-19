--
-- /usr/commands/xe_dashboard.lua
-- XE v2 demo: system dashboard with all widget types
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
    },
})
if not ctx then print("xe: no context"); return end

-- State
local running   = true
local frames    = 0
local sFilter   = ""
local bShowDead = false
local bShowSys  = true
local view      = "Processes"
local menu      = {"Processes", "Memory", "Extensions", "About"}

while running do
    ctx:beginFrame()
    ctx:clear(ctx:c("bg"))
    frames = frames + 1

    local W, H = ctx.W, ctx.H

    -- ============ TOP BAR ============
    ctx:fill(1, 1, W, 1, " ", ctx:c("bar_fg"), ctx:c("bar_bg"))
    ctx:text(2, 1, "XE Dashboard", ctx:c("accent"), ctx:c("bar_bg"))
    ctx:textf(W - 18, 1, ctx:c("dim"), ctx:c("bar_bg"),
              "F:%d  Tab:Nav  Q:Quit", frames)

    -- ============ LEFT MENU (3..H-2) ============
    local menuW = 18
    ctx:box(1, 3, menuW, #menu + 2, "View", ctx:c("fg"), ctx:c("bg"), ctx:c("border"))
    for i, item in ipairs(menu) do
        if ctx:selectable("menu_" .. i, 2, 3 + i, menuW - 2, " " .. item,
            ctx:c("fg"), ctx:c("bg"), ctx:c("sel_fg"), ctx:c("sel_bg")) then
            view = item
        end
    end

    -- ============ MAIN PANEL ============
    local px  = menuW + 2
    local py  = 3
    local pw  = W - px
    local ph  = H - 5
    ctx:box(px, py, pw, ph, view, ctx:c("fg"), ctx:c("bg"), ctx:c("border"))

    local cx = px + 2
    local cy = py + 2
    local cw = pw - 4

    if view == "Processes" then
        -- ---- Filter input ----
        ctx:label(cx, cy, "Filter:", ctx:c("dim"))
        local newFilter, fChanged = ctx:textInput(
            "filter", cx + 8, cy, cw - 8, sFilter)
        if fChanged then sFilter = newFilter end
        cy = cy + 1

        -- ---- Checkboxes ----
        local nCkY = cy
        bShowDead, _ = ctx:checkbox("chk_dead", cx, nCkY,
            bShowDead, "Show dead")
        bShowSys, _  = ctx:checkbox("chk_sys", cx + 20, nCkY,
            bShowSys, "Show system (PID<5)")
        cy = cy + 1

        ctx:separator(cx, cy, cw, ctx:c("border"))
        cy = cy + 1

        -- ---- Build process list ----
        local tProcs = syscall("process_list") or {}
        local tFiltered = {}
        for _, p in ipairs(tProcs) do
            if not bShowDead and p.status == "dead" then goto skip end
            if not bShowSys and p.pid < 5 then goto skip end
            if #sFilter > 0 then
                local sEntry = tostring(p.pid) .. " " .. (p.image or "")
                if not sEntry:lower():find(sFilter:lower(), 1, true) then
                    goto skip
                end
            end
            tFiltered[#tFiltered + 1] = p
            ::skip::
        end

        -- ---- Scrollable list ----
        local scrollH = py + ph - 3 - cy
        if scrollH < 3 then scrollH = 3 end

        -- Header
        ctx:textf(cx, cy, ctx:c("dim"), ctx:c("bg"),
            "%-5s %-4s %-8s %s", "PID", "RING", "STATUS", "IMAGE")
        cy = cy + 1

        local first, last, sel, scW, bAct = ctx:beginScroll(
            "proclist", cx, cy, cw, scrollH, #tFiltered)

        for i = first, last do
            local p = tFiltered[i]
            local ry = cy + (i - first)
            local bSel = (i == sel)

            local sFg = ctx:c("fg")
            local sBg = ctx:c("bg")
            if p.status == "dead" then sFg = ctx:c("dim")
            elseif p.ring <= 1 then sFg = ctx:c("warn")
            elseif p.ring <= 2 then sFg = ctx:c("accent") end

            if bSel then sFg = ctx:c("sel_fg"); sBg = ctx:c("sel_bg") end

            local sImg = (p.image or "?")
            if #sImg > scW - 22 then sImg = ".." .. sImg:sub(-(scW - 24)) end

            ctx:textPad(cx, ry, scW,
                string.format("%-5d %-4s %-8s %s",
                    p.pid, tostring(p.ring), p.status, sImg),
                sFg, sBg)
        end
        ctx:endScroll()

        -- Activated item info
        if bAct and tFiltered[sel] then
            local p = tFiltered[sel]
            ctx:text(cx, py + ph - 3,
                string.format("Selected: PID %d  %s", p.pid, p.image or "?"),
                ctx:c("accent2"))
        end

    elseif view == "Memory" then
        local nT = computer.totalMemory()
        local nF = computer.freeMemory()
        local nU = nT - nF
        local pct = math.floor(nU / nT * 100)

        ctx:textf(cx, cy, ctx:c("accent"), nil,
            "Total:  %7.1f KB", nT / 1024)
        cy = cy + 1
        ctx:textf(cx, cy, pct > 80 and ctx:c("err") or ctx:c("ok"), nil,
            "Used:   %7.1f KB  (%d%%)", nU / 1024, pct)
        cy = cy + 1
        ctx:textf(cx, cy, ctx:c("ok"), nil,
            "Free:   %7.1f KB", nF / 1024)
        cy = cy + 2

        ctx:label(cx, cy, "Usage:")
        ctx:progress(cx + 8, cy, 30, pct, nil, 0x222233, nil,
            pct > 80 and 0xAA0000 or 0x00AA44)
        ctx:textf(cx + 40, cy, pct > 80 and ctx:c("err") or ctx:c("ok"), nil,
            "%d%%", pct)
        cy = cy + 2

        ctx:textf(cx, cy, ctx:c("dim"), nil, "Frame: %d", frames)
        cy = cy + 1
        local up = computer.uptime()
        ctx:textf(cx, cy, ctx:c("dim"), nil, "Uptime: %d:%02d:%02d",
            math.floor(up/3600), math.floor(up%3600/60), math.floor(up%60))

        if nF < 32768 then
            cy = cy + 2
            ctx:text(cx, cy, "!! LOW MEMORY !!", ctx:c("err"))
        end

    elseif view == "Extensions" then
        ctx:text(cx, cy, "Loaded extensions:", ctx:c("accent"))
        cy = cy + 2
        local exts = xe.enumerateExtensions()
        for _, name in ipairs(exts) do
            local on = ctx._ext[name]
            ctx:text(cx, cy, (on and "[*] " or "[ ] ") .. name,
                on and ctx:c("ok") or ctx:c("dim"))
            cy = cy + 1
        end
        cy = cy + 1
        ctx:label(cx, cy, "Rendering stats:")
        cy = cy + 1
        ctx:textf(cx + 2, cy, ctx:c("fg"), nil,
            "Batch entries this frame: %d", ctx._nB)
        cy = cy + 1
        ctx:textf(cx + 2, cy, ctx:c("fg"), nil,
            "Shadow buffer: %s   Diff: %s   Run-group: %s",
            ctx._bShadow and "ON" or "off",
            ctx._bDiff   and "ON" or "off",
            ctx._bRunGrp and "ON" or "off")

    elseif view == "About" then
        ctx:text(cx, cy, "XE Graphics v2 for AxisOS", ctx:c("accent"))
        cy = cy + 2
        local info = {
            "Byte-array shadow buffer (zero string alloc per cell)",
            "Per-cell diff with gap-bridging run grouping",
            "Deferred clears via single gpu_fill",
            "Large fill optimization (direct gpu_fill)",
            "IMGUI widgets: button, selectable, checkbox",
            "Scroll container with scrollbar",
            "Text input with cursor and scrolling",
            "Clip region stack (nested containers)",
            "Theme system (dark / light)",
            "Pre-cached space strings",
            "Dirty-row tracking (skip untouched rows)",
        }
        for _, l in ipairs(info) do
            ctx:text(cx, cy, "  * " .. l, ctx:c("ok"))
            cy = cy + 1
        end
    end

    -- ============ BOTTOM BAR ============
    ctx:fill(1, H, W, 1, " ", ctx:c("bar_fg"), ctx:c("bar_bg"))
    if ctx:button("quit", 2, H, " Quit ",
        ctx:c("btn_fg"), 0xAA2222,
        ctx:c("btn_hfg"), 0xFF4444) then
        running = false
    end

    ctx:textf(W - 14, H, ctx:c("dim"), ctx:c("bar_bg"),
        "%d procs", #(syscall("process_list") or {}))

    -- Global hotkey
    local k = ctx:key()
    if k == "q" or k == "\3" then running = false end

    ctx:endFrame()
end

ctx:destroy()