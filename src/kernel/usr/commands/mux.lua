-- /usr/commands/mux.lua
-- Terminal multiplexer for AxisOS
-- Ctrl+B = prefix key

local gx = require("gx")
local inst = gx.createInstance({
    extensions = {
        "GX_AX_surface", "GX_AX_input", "GX_AX_present",
        "GX_AX_query", "GX_EXT_text_buffer", "GX_EXT_layers",
    },
})

local tGpu = inst:getGpuInfo(1)
local SW, SH = tGpu.nW, tGpu.nH

-- ═══════════════════════════════════
-- STATE
-- ═══════════════════════════════════

local tPanes   = {}
local nFocused = 0
local bRunning = true

-- Hidden control surface: captures ALL keyboard input
local hControl = inst:createSurface(1, 1, {
    bVisible = false, sLabel = "mux:ctrl",
})
inst:setFocus(hControl)

-- Status bar: z-order 100, bottom row
local hStatus = inst:createSurface(SW, 1, {
    nScreenX = 1, nScreenY = SH,
    nZOrder  = 100,
    sLabel   = "mux:status",
})

-- ═══════════════════════════════════
-- PANE MANAGEMENT
-- ═══════════════════════════════════

local function addPane(nX, nY, nW, nH)
    local h = inst:createSurface(nW, nH, {
        nScreenX = nX, nScreenY = nY,
        nZOrder  = 10,
        sLabel   = "mux:pane:" .. (#tPanes + 1),
    })

    -- Spawn shell targeting this surface
    local nPid = syscall("process_spawn", "/bin/sh.lua", {
        env = { GX_SURFACE = tostring(h) },
    })

    tPanes[#tPanes + 1] = {
        h    = h,
        nPid = nPid,
        nX = nX, nY = nY, nW = nW, nH = nH,
    }
    return #tPanes
end

local function killPane(nIdx)
    local p = tPanes[nIdx]
    if not p then return end
    if p.nPid then pcall(syscall, "process_kill", p.nPid) end
    inst:destroySurface(p.h)
    table.remove(tPanes, nIdx)
end

local function focusPane(nIdx)
    nIdx = math.max(1, math.min(nIdx, #tPanes))
    nFocused = nIdx
    -- Visual: highlight focused pane border (future)
end

-- ═══════════════════════════════════
-- SPLITTING
-- ═══════════════════════════════════

local function splitVertical()
    if #tPanes == 0 then return end
    local p = tPanes[nFocused]
    if p.nW < 20 then return end

    local nHalf = math.floor(p.nW / 2)

    -- Shrink current pane
    p.nW = nHalf - 1
    inst:resizeSurface(p.h, p.nW, p.nH)
    inst:setPosition(p.h, p.nX, p.nY)

    -- New pane in right half
    addPane(p.nX + nHalf, p.nY, SW - p.nX - nHalf + 1, p.nH)
end

local function splitHorizontal()
    if #tPanes == 0 then return end
    local p = tPanes[nFocused]
    if p.nH < 8 then return end

    local nHalf = math.floor(p.nH / 2)

    -- Shrink current
    p.nH = nHalf - 1
    inst:resizeSurface(p.h, p.nW, p.nH)

    -- New pane below
    addPane(p.nX, p.nY + nHalf, p.nW, SH - 1 - p.nY - nHalf + 1)
end

-- ═══════════════════════════════════
-- STATUS BAR
-- ═══════════════════════════════════

local function updateStatus()
    inst:fill(hStatus, 1, 1, SW, 1, " ", 0x000000, 0x55FF55)

    local sx = 2
    for i, p in ipairs(tPanes) do
        local sAlive = p.nPid and "+" or "x"
        local sLbl = string.format(" %d%s ", i, sAlive)
        local nFg = (i == nFocused) and 0xFFFFFF or 0x000000
        local nBg = (i == nFocused) and 0x0000AA or 0x55FF55
        inst:set(hStatus, sx, 1, sLbl, nFg, nBg)
        sx = sx + #sLbl + 1
    end

    local sRight = string.format(" mux | %d pane(s) ", #tPanes)
    inst:set(hStatus, SW - #sRight, 1, sRight, 0x000000, 0x55FF55)
end

-- ═══════════════════════════════════
-- DRAW PANE BORDERS
-- ═══════════════════════════════════

local function drawBorders()
    -- Simple: fill a 1-char separator between adjacent panes
    -- (For v1 this is cosmetic, not functional)
    for i, p in ipairs(tPanes) do
        -- Right edge separator
        if p.nX + p.nW < SW then
            local hBorder = nil  -- could use a thin surface
            -- For now, just leave the gap
        end
    end
end

-- ═══════════════════════════════════
-- START: one full-screen pane
-- ═══════════════════════════════════

addPane(1, 1, SW, SH - 1)
focusPane(1)

-- ═══════════════════════════════════
-- MAIN LOOP
-- ═══════════════════════════════════

local bPrefix = false

while bRunning do
    -- Poll for input on control surface
    local evt = inst:popInput(hControl)

    if evt and evt.sType == "key_down" then
        local ch   = evt.nChar
        local code = evt.nCode

        if bPrefix then
            bPrefix = false
            local c = ch >= 32 and ch < 127 and string.char(ch) or ""

            if c == "%" or c == "v" then
                splitVertical()

            elseif c == '"' or c == "h" then
                splitHorizontal()

            elseif c == "o" or c == "\t" then
                focusPane((nFocused % #tPanes) + 1)

            elseif c == "n" then
                focusPane(nFocused + 1)

            elseif c == "p" then
                focusPane(nFocused - 1)

            elseif c == "x" then
                killPane(nFocused)
                if #tPanes == 0 then
                    bRunning = false
                else
                    focusPane(math.min(nFocused, #tPanes))
                end

            elseif c == "c" then
                -- New pane (full width, split from bottom)
                splitHorizontal()

            elseif c == "d" then
                -- Detach: leave shells running, exit mux
                bRunning = false

            elseif c == "1" or c == "2" or c == "3" or c == "4"
                or c == "5" or c == "6" or c == "7" or c == "8"
                or c == "9" then
                local nTarget = tonumber(c)
                if nTarget <= #tPanes then focusPane(nTarget) end
            end
            -- If prefix + unrecognized key: drop it

        elseif ch == 2 then -- Ctrl+B = prefix
            bPrefix = true

        else
            -- Forward to focused pane
            if nFocused > 0 and tPanes[nFocused] then
                inst:pushInput(tPanes[nFocused].h, evt)
            end
        end

    elseif evt and evt.sType == "key_up" then
        -- Forward key_up to focused pane
        if nFocused > 0 and tPanes[nFocused] then
            inst:pushInput(tPanes[nFocused].h, evt)
        end
    end

    -- Clean up dead panes
    for i = #tPanes, 1, -1 do
        if tPanes[i].nPid then
            local tInfo = syscall("process_info", tPanes[i].nPid)
            if not tInfo or tInfo.status == "dead" then
                tPanes[i].nPid = nil
            end
        end
    end

    updateStatus()
    inst:present()
    coroutine.yield()
end

-- Cleanup
for i = #tPanes, 1, -1 do killPane(i) end
inst:destroySurface(hStatus)
inst:destroySurface(hControl)
inst:destroy()