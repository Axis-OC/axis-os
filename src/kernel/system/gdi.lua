-- /system/gdi.lua
-- Graphics Device Interface v3.3 — Deferred Clear Compositor
--
-- v3.3 fixes:
--   - No more blinking: SurfaceSetPosition defers clears to compositor
--   - DestroySurface properly clears screen area
--   - SurfaceSetVisible properly clears hidden surface area
--   - OnTouchEvent clears stale drag state

local GDI = {}

local g_tGpus           = {}
local g_tScreens        = {}
local g_tSurfaces       = {}
local g_nNextHandle     = 1
local g_nFocusedSurface = nil
local g_tInputQueues    = {}
local g_tScreenBuf      = {}
local g_fLog            = function() end
local g_nMaxZSeen       = 0

local g_tPipelineState  = {}
local g_tFastPath       = nil

local g_tSwapchains     = {}
local g_nNextSwapHandle = 1

local g_tCmdBuffers     = {}
local g_nNextCmdHandle  = 1

local g_bForceRedrawPending = false

local g_tPendingClears  = {}

local g_tDragState = {
    bActive    = false,
    hSurface   = nil,
    nOffX      = 0,
    nOffY      = 0,
}
local g_nDesktopBg = 0x000000
local g_nDesktopFg = 0xFFFFFF

function GDI.SetDesktopBackground(nFg, nBg)
    g_nDesktopFg = nFg or 0xFFFFFF
    g_nDesktopBg = nBg or 0x000000
end

-- ═══ HELPERS ═══

local function _ulen(s)
    if not s then return 0 end
    if unicode and unicode.len then
        local ok, n = pcall(unicode.len, s)
        if ok and n then return n end
    end
    return #s
end

local function _usub(s, i, j)
    if not s then return "" end
    if unicode and unicode.sub then
        local ok, r = pcall(unicode.sub, s, i, j)
        if ok and r then return r end
    end
    return s:sub(i, j)
end

local function _newRow(nW, nFg, nBg)
    nFg = nFg or 0xFFFFFF; nBg = nBg or 0x000000
    local tCh, tFg, tBg = {}, {}, {}
    for x = 1, nW do tCh[x] = " "; tFg[x] = nFg; tBg[x] = nBg end
    return { tCh = tCh, tFg = tFg, tBg = tBg, bDirty = true }
end

-- ═══ LOW-LEVEL GPU ═══

local function _gpuSetFg(nGpuIdx, nColor)
    local tPS = g_tPipelineState[nGpuIdx]; if not tPS then return end
    if tPS.nLastFg == nColor then return end
    local tGpu = g_tGpus[nGpuIdx]
    if tGpu and tGpu.proxy then tGpu.proxy.setForeground(nColor); tPS.nLastFg = nColor end
end

local function _gpuSetBg(nGpuIdx, nColor)
    local tPS = g_tPipelineState[nGpuIdx]; if not tPS then return end
    if tPS.nLastBg == nColor then return end
    local tGpu = g_tGpus[nGpuIdx]
    if tGpu and tGpu.proxy then tGpu.proxy.setBackground(nColor); tPS.nLastBg = nColor end
end

local function _gpuSet(nGpuIdx, nX, nY, sText, nFg, nBg)
    _gpuSetFg(nGpuIdx, nFg); _gpuSetBg(nGpuIdx, nBg)
    local tGpu = g_tGpus[nGpuIdx]
    if tGpu and tGpu.proxy then tGpu.proxy.set(nX, nY, sText) end
end

local function _gpuFill(nGpuIdx, nX, nY, nW, nH, sCh, nFg, nBg)
    _gpuSetFg(nGpuIdx, nFg); _gpuSetBg(nGpuIdx, nBg)
    local tGpu = g_tGpus[nGpuIdx]
    if tGpu and tGpu.proxy then tGpu.proxy.fill(nX, nY, nW, nH, sCh or " ") end
end

local function _gpuInvalidatePipeline(nGpuIdx)
    local tPS = g_tPipelineState[nGpuIdx]
    if tPS then tPS.nLastFg = -1; tPS.nLastBg = -1 end
end

-- Helper: queue a screen rectangle for deferred clearing
local function _queueClear(nGpuIdx, nSX, nSY, nSW, nSH)
    local tGpu = g_tGpus[nGpuIdx]; if not tGpu then return end
    local x1 = math.max(1, nSX)
    local y1 = math.max(1, nSY)
    local x2 = math.min(tGpu.nW, nSX + nSW - 1)
    local y2 = math.min(tGpu.nH, nSY + nSH - 1)
    if x1 <= x2 and y1 <= y2 then
        g_tPendingClears[#g_tPendingClears + 1] = {
            nGpuIdx = nGpuIdx, x1 = x1, y1 = y1, x2 = x2, y2 = y2,
        }
    end
end

-- Helper: mark all visible surfaces on a GPU as dirty
local function _markGpuDirty(nGpuIdx)
    for _, surf in pairs(g_tSurfaces) do
        if surf.bVisible and surf.nGpuTarget == nGpuIdx then
            for y = 1, surf.nH do surf.tRows[y].bDirty = true end
        end
    end
end

-- ═══ INIT / GPU MANAGEMENT ═══

function GDI.Initialize(tOpts)
    g_fLog = tOpts.fLog or g_fLog
    local nIdx = 0
    for sAddr in raw_component.list("gpu") do
        nIdx = nIdx + 1
        g_tGpus[nIdx] = {
            address = sAddr, proxy = raw_component.proxy(sAddr),
            screenAddr = nil, nW = 0, nH = 0, nMaxW = 0, nMaxH = 0,
        }
        g_tPipelineState[nIdx] = { nLastFg = -1, nLastBg = -1 }
    end
    local nScr = 0
    for sAddr in raw_component.list("screen") do
        nScr = nScr + 1; g_tScreens[sAddr] = { address = sAddr, gpuIdx = nil }
    end
    local tScreenAddrs = {}
    for sAddr in pairs(g_tScreens) do tScreenAddrs[#tScreenAddrs + 1] = sAddr end
    table.sort(tScreenAddrs)
    for i, sAddr in ipairs(tScreenAddrs) do
        if g_tGpus[i] then GDI.BindGpu(i, sAddr) end
    end
    g_fLog(string.format("[GDI] v3.3 initialized: %d GPU(s), %d screen(s)", nIdx, nScr))
    return true
end

function GDI.BindGpu(nIdx, sScreenAddr)
    local tGpu = g_tGpus[nIdx]; if not tGpu then return nil, "bad gpu index" end
    tGpu.proxy.bind(sScreenAddr); tGpu.screenAddr = sScreenAddr
    tGpu.nMaxW, tGpu.nMaxH = tGpu.proxy.maxResolution()
    tGpu.proxy.setResolution(tGpu.nMaxW, tGpu.nMaxH)
    tGpu.nW, tGpu.nH = tGpu.proxy.getResolution()
    g_tScreenBuf[nIdx] = {}
    for y = 1, tGpu.nH do
        g_tScreenBuf[nIdx][y] = _newRow(tGpu.nW)
        g_tScreenBuf[nIdx][y].bDirty = false
    end
    _gpuInvalidatePipeline(nIdx)
    -- _gpuFill(nIdx, 1, 1, tGpu.nW, tGpu.nH, " ", 0xFFFFFF, 0x000000)
    if g_tScreens[sScreenAddr] then g_tScreens[sScreenAddr].gpuIdx = nIdx end
    g_fLog(string.format("[GDI] GPU %d -> %s (%dx%d)", nIdx, sScreenAddr:sub(1, 8), tGpu.nW, tGpu.nH))
    return true
end

function GDI.AttachGpuDriver(tFP) g_tFastPath = tFP; g_fLog("[GDI] GPU driver fast-path attached"); return true end
function GDI.HasGpuDriver() return g_tFastPath ~= nil end

-- ═══ SURFACE LIFECYCLE ═══

function GDI.CreateSurface(nW, nH, tOpts)
    tOpts = tOpts or {}
    local h = g_nNextHandle; g_nNextHandle = g_nNextHandle + 1
    local tRows = {}
    for y = 1, nH do tRows[y] = _newRow(nW) end
    local nZ = tOpts.nZOrder or 0
    if nZ > g_nMaxZSeen then g_nMaxZSeen = nZ end
    g_tSurfaces[h] = {
        nHandle = h, nW = nW, nH = nH, tRows = tRows,
        nGpuTarget = tOpts.nGpuTarget or 1,
        nScreenX = tOpts.nScreenX or 1, nScreenY = tOpts.nScreenY or 1,
        nZOrder = nZ, nOwnerPid = tOpts.nOwnerPid or 0,
        bVisible = tOpts.bVisible ~= false,
        bDraggable = tOpts.bDraggable ~= false,
        nTitleHeight = tOpts.nTitleHeight or 1,
        sLabel = tOpts.sLabel or "",
    }
    g_tInputQueues[h] = {}
    return h
end

function GDI.DestroySurface(h)
    local s = g_tSurfaces[h]
    if s and s.bVisible then
        -- Queue the occupied area for deferred clearing
        _queueClear(s.nGpuTarget, s.nScreenX, s.nScreenY, s.nW, s.nH)
        _markGpuDirty(s.nGpuTarget)
    end
    g_tSurfaces[h] = nil
    g_tInputQueues[h] = nil
    if g_nFocusedSurface == h then g_nFocusedSurface = nil end
end

function GDI.ResizeSurface(h, nNewW, nNewH)
    local s = g_tSurfaces[h]; if not s then return nil, "bad handle" end
    _queueClear(s.nGpuTarget, s.nScreenX, s.nScreenY, s.nW, s.nH)
    local tNewRows = {}
    for y = 1, nNewH do
        if y <= s.nH then
            local old = s.tRows[y]; local r = _newRow(nNewW)
            for x = 1, math.min(s.nW, nNewW) do
                r.tCh[x] = old.tCh[x]; r.tFg[x] = old.tFg[x]; r.tBg[x] = old.tBg[x]
            end
            tNewRows[y] = r
        else tNewRows[y] = _newRow(nNewW) end
    end
    s.tRows = tNewRows; s.nW = nNewW; s.nH = nNewH
    _markGpuDirty(s.nGpuTarget)
    return true
end

-- ═══ SURFACE DRAWING (Unicode-Aware) ═══

function GDI.SurfaceSet(h, nX, nY, sText, nFg, nBg)
    local s = g_tSurfaces[h]; if not s then return nil, "bad handle" end
    if nY < 1 or nY > s.nH then return true end
    local r = s.tRows[nY]; local nULen = _ulen(sText)
    for i = 1, nULen do
        local cx = nX + i - 1
        if cx >= 1 and cx <= s.nW then
            r.tCh[cx] = _usub(sText, i, i)
            if nFg then r.tFg[cx] = nFg end
            if nBg then r.tBg[cx] = nBg end
        end
    end
    r.bDirty = true; return true
end

function GDI.SurfaceFill(h, nX, nY, nW, nH, sChar, nFg, nBg)
    local s = g_tSurfaces[h]; if not s then return nil, "bad handle" end
    sChar = sChar and _usub(sChar, 1, 1) or " "
    for y = math.max(1, nY), math.min(s.nH, nY + nH - 1) do
        local r = s.tRows[y]
        for x = math.max(1, nX), math.min(s.nW, nX + nW - 1) do
            r.tCh[x] = sChar
            if nFg then r.tFg[x] = nFg end
            if nBg then r.tBg[x] = nBg end
        end
        r.bDirty = true
    end
    return true
end

function GDI.SurfaceScroll(h, nLines)
    local s = g_tSurfaces[h]; if not s then return nil end
    if nLines > 0 then
        for _ = 1, math.min(nLines, s.nH) do
            table.remove(s.tRows, 1); s.tRows[s.nH] = _newRow(s.nW)
        end
    elseif nLines < 0 then
        for _ = 1, math.min(-nLines, s.nH) do
            table.remove(s.tRows, s.nH); table.insert(s.tRows, 1, _newRow(s.nW))
        end
    end
    for y = 1, s.nH do s.tRows[y].bDirty = true end
    return true
end

function GDI.SurfaceClear(h, nFg, nBg)
    local s = g_tSurfaces[h]; if not s then return nil end
    for y = 1, s.nH do s.tRows[y] = _newRow(s.nW, nFg, nBg) end
    return true
end

function GDI.SurfaceSetVisible(h, b)
    local s = g_tSurfaces[h]; if not s then return nil end
    if s.bVisible ~= b then
        if s.bVisible and not b then
            -- Hiding → queue old area for deferred clear
            _queueClear(s.nGpuTarget, s.nScreenX, s.nScreenY, s.nW, s.nH)
        end
        s.bVisible = b
        _markGpuDirty(s.nGpuTarget)
    end
    return true
end

function GDI.SurfaceSetPosition(h, nX, nY)
    local s = g_tSurfaces[h]; if not s then return nil end
    if s.nScreenX == nX and s.nScreenY == nY then return true end

    -- Queue OLD position for deferred clear (NO direct GPU fill)
    if s.bVisible then
        _queueClear(s.nGpuTarget, s.nScreenX, s.nScreenY, s.nW, s.nH)
    end

    s.nScreenX = nX; s.nScreenY = nY

    -- Mark all visible surfaces on this GPU dirty for correct compositing
    _markGpuDirty(s.nGpuTarget)
    return true
end

function GDI.SurfaceSetZ(h, nZ)
    local s = g_tSurfaces[h]; if not s then return nil end
    s.nZOrder = nZ; if nZ > g_nMaxZSeen then g_nMaxZSeen = nZ end; return true
end

function GDI.SurfaceBringToFront(h)
    g_nMaxZSeen = g_nMaxZSeen + 1; return GDI.SurfaceSetZ(h, g_nMaxZSeen)
end

function GDI.SurfaceMarkDirty(h)
    local s = g_tSurfaces[h]; if not s then return nil end
    for y = 1, s.nH do s.tRows[y].bDirty = true end; return true
end

function GDI.SurfaceSetGpu(h, nGpuIdx)
    local s = g_tSurfaces[h]; if not s then return nil end
    s.nGpuTarget = nGpuIdx
    for y = 1, s.nH do s.tRows[y].bDirty = true end; return true
end

function GDI.SurfaceGetSize(h)
    local s = g_tSurfaces[h]; if not s then return nil end; return s.nW, s.nH
end

-- ═══ FORCE FULL REDRAW ═══

function GDI.ForceFullRedraw()
    -- Use pending clears for the entire screen instead of just a flag
    for nGIdx, tGpu in pairs(g_tGpus) do
        if tGpu.screenAddr then
            _queueClear(nGIdx, 1, 1, tGpu.nW, tGpu.nH)
        end
    end
    for _, s in pairs(g_tSurfaces) do
        for y = 1, s.nH do s.tRows[y].bDirty = true end
    end
end

-- ═══ COMPOSITOR — No-Blink Deferred Clear ═══

function GDI.Composite()
    local nTotalCalls = 0

    for nGpuIdx, tGpu in pairs(g_tGpus) do
        if not tGpu.screenAddr then goto nextGpu end
        local oGpu = tGpu.proxy
        local tSBuf = g_tScreenBuf[nGpuIdx]
        if not tSBuf then goto nextGpu end

        local nScrW = tGpu.nW
        local nScrH = tGpu.nH

        -- Collect visible surfaces sorted by Z
        local tVis = {}
        for _, s in pairs(g_tSurfaces) do
            if s.bVisible and s.nGpuTarget == nGpuIdx then
                tVis[#tVis + 1] = s
            end
        end
        table.sort(tVis, function(a, b) return a.nZOrder < b.nZOrder end)

        local tBatch = {}
        local nBatch = 0

        -- === PASS 1: Composite visible surfaces ===
        for _, s in ipairs(tVis) do
            for sy = 1, s.nH do
                local r = s.tRows[sy]
                if not r.bDirty then goto nextSRow end
                local nPhysY = s.nScreenY + sy - 1
                if nPhysY < 1 or nPhysY > nScrH then goto nextSRow end
                local tScr = tSBuf[nPhysY]

                for x = 1, s.nW do
                    local nPhysX = s.nScreenX + x - 1
                    if nPhysX < 1 or nPhysX > nScrW then goto nextCell end
                    local nFg = r.tFg[x]
                    local nBg = r.tBg[x]
                    local sCh = r.tCh[x]
                    if sCh ~= tScr.tCh[nPhysX] or nFg ~= tScr.tFg[nPhysX]
                       or nBg ~= tScr.tBg[nPhysX] then
                        nBatch = nBatch + 1
                        tBatch[nBatch] = { nPhysX, nPhysY, sCh, nFg, nBg }
                        tScr.tCh[nPhysX] = sCh
                        tScr.tFg[nPhysX] = nFg
                        tScr.tBg[nPhysX] = nBg
                    end
                    ::nextCell::
                end
                r.bDirty = false
                ::nextSRow::
            end
        end

        -- === PASS 2: Deferred clears — fix uncovered cells ===
        -- Only runs when surfaces moved, were hidden, or destroyed.
        local nClrIdx = 1
        while nClrIdx <= #g_tPendingClears do
            local tc = g_tPendingClears[nClrIdx]
            if tc.nGpuIdx == nGpuIdx then
                table.remove(g_tPendingClears, nClrIdx)
                for cy = tc.y1, tc.y2 do
                    if cy >= 1 and cy <= nScrH then
                        local tScr = tSBuf[cy]
                        for cx = tc.x1, tc.x2 do
                            if cx >= 1 and cx <= nScrW then
                                -- Is this cell covered by any visible surface?
                                local bCovered = false
                                for _, sv in ipairs(tVis) do
                                    if cx >= sv.nScreenX and cx < sv.nScreenX + sv.nW
                                       and cy >= sv.nScreenY and cy < sv.nScreenY + sv.nH then
                                        bCovered = true; break
                                    end
                                end
                                if not bCovered then
                                    if tScr.tCh[cx] ~= " "
                                       or tScr.tFg[cx] ~= g_nDesktopFg
                                       or tScr.tBg[cx] ~= g_nDesktopBg then
                                        nBatch = nBatch + 1
                                        tBatch[nBatch] = { cx, cy, " ", g_nDesktopFg, g_nDesktopBg }
                                        tScr.tCh[cx] = " "
                                        tScr.tFg[cx] = g_nDesktopFg
                                        tScr.tBg[cx] = g_nDesktopBg
                                    end
                                end
                            end
                        end
                    end
                end
            else
                nClrIdx = nClrIdx + 1
            end
        end

        if nBatch == 0 then goto nextGpu end

        -- Sort by color then position for minimal GPU state changes
        table.sort(tBatch, function(a, b)
            local ka = a[4] * 0x1000000 + a[5]
            local kb = b[4] * 0x1000000 + b[5]
            if ka ~= kb then return ka < kb end
            if a[2] ~= b[2] then return a[2] < b[2] end
            return a[1] < b[1]
        end)

        -- Group into text runs and send to GPU
        local i = 1
        while i <= nBatch do
            local t = tBatch[i]
            local nFg, nBg = t[4], t[5]
            local tChars = { t[3] }
            local nRunX, nRunY = t[1], t[2]
            local nExpectX = nRunX + 1
            i = i + 1
            while i <= nBatch do
                local tn = tBatch[i]
                if tn[4] ~= nFg or tn[5] ~= nBg then break end
                if tn[2] ~= nRunY or tn[1] ~= nExpectX then break end
                tChars[#tChars + 1] = tn[3]
                nExpectX = nExpectX + 1; i = i + 1
            end
            _gpuSetFg(nGpuIdx, nFg); _gpuSetBg(nGpuIdx, nBg)
            oGpu.set(nRunX, nRunY, table.concat(tChars))
            nTotalCalls = nTotalCalls + 1
        end
        ::nextGpu::
    end
    return nTotalCalls
end

-- ═══ INPUT ROUTING ═══

function GDI.SetFocus(h) g_nFocusedSurface = h end
function GDI.GetFocus() return g_nFocusedSurface end

function GDI.PushInput(h, tEvent)
    local q = g_tInputQueues[h]; if not q then return nil end
    q[#q + 1] = tEvent; return true
end

function GDI.PopInput(h)
    local q = g_tInputQueues[h]
    if not q or #q == 0 then return nil end
    return table.remove(q, 1)
end

function GDI.InputQueueSize(h)
    local q = g_tInputQueues[h]; return q and #q or 0
end

function GDI.OnKeyEvent(sType, sKbAddr, nChar, nCode, sPlayer)
    if not g_nFocusedSurface then return end
    GDI.PushInput(g_nFocusedSurface, {
        sType = sType, nChar = nChar, nCode = nCode, sPlayer = sPlayer,
    })
end

function GDI.OnTouchEvent(sScreenAddr, nX, nY, nButton, sPlayer)
    nX = math.floor(nX); nY = math.floor(nY)

    -- Clear stale drag state on any new touch
    if g_tDragState.bActive then
        g_tDragState.bActive = false
        g_tDragState.hSurface = nil
    end

    local tHit, nBestZ = nil, -1
    for _, s in pairs(g_tSurfaces) do
        if s.bVisible and s.nZOrder > nBestZ then
            if nX >= s.nScreenX and nX < s.nScreenX + s.nW
               and nY >= s.nScreenY and nY < s.nScreenY + s.nH then
                tHit = s; nBestZ = s.nZOrder
            end
        end
    end
    if not tHit then return false end

    g_nMaxZSeen = g_nMaxZSeen + 1
    tHit.nZOrder = g_nMaxZSeen

    local nTitleH = tHit.nTitleHeight or 1
    if nY >= tHit.nScreenY and nY < tHit.nScreenY + nTitleH
       and (tHit.bDraggable ~= false) then
        local nCloseX = tHit.nScreenX + tHit.nW - 4
        if nX >= nCloseX and nX < nCloseX + 4 then
            GDI.PushInput(tHit.nHandle, { sType = "close_requested", nX = nX, nY = nY })
            return true
        end
        g_tDragState.bActive = true
        g_tDragState.hSurface = tHit.nHandle
        g_tDragState.nOffX = nX - tHit.nScreenX
        g_tDragState.nOffY = nY - tHit.nScreenY
        g_nFocusedSurface = tHit.nHandle
        return true
    end

    g_nFocusedSurface = tHit.nHandle
    GDI.PushInput(tHit.nHandle, {
        sType = "touch", nX = nX - tHit.nScreenX + 1, nY = nY - tHit.nScreenY + 1, nButton = nButton,
    })
    return true
end

function GDI.OnDragEvent(sScreenAddr, nX, nY, nButton, sPlayer)
    nX = math.floor(nX); nY = math.floor(nY)
    if g_tDragState.bActive then
        local s = g_tSurfaces[g_tDragState.hSurface]
        if s then
            local nNewX = nX - g_tDragState.nOffX
            local nNewY = nY - g_tDragState.nOffY
            local tGpu = g_tGpus[s.nGpuTarget]
            if tGpu then
                nNewX = math.max(1, math.min(nNewX, tGpu.nW - s.nW + 1))
                nNewY = math.max(1, math.min(nNewY, tGpu.nH - s.nH + 1))
            end
            GDI.SurfaceSetPosition(g_tDragState.hSurface, nNewX, nNewY)
            GDI.Composite()
        end
        return true
    end
    if g_nFocusedSurface then
        local s = g_tSurfaces[g_nFocusedSurface]
        if s then
            GDI.PushInput(g_nFocusedSurface, {
                sType = "drag", nX = nX - s.nScreenX + 1, nY = nY - s.nScreenY + 1, nButton = nButton,
            })
        end
    end
    return false
end

function GDI.OnDropEvent(sScreenAddr, nX, nY, nButton, sPlayer)
    if g_tDragState.bActive then
        g_tDragState.bActive = false; g_tDragState.hSurface = nil; return true
    end
    return false
end

function GDI.OnScrollEvent(sScreenAddr, nX, nY, nDir, sPlayer)
    nX = math.floor(nX); nY = math.floor(nY)
    if g_nFocusedSurface then
        GDI.PushInput(g_nFocusedSurface, { sType = "scroll", nX = nX, nY = nY, nDir = nDir })
        return true
    end
    return false
end

-- ═══ BATCH SUBMIT ═══

function GDI.BatchSubmit(h, tOps)
    for _, op in ipairs(tOps) do
        local cmd = op[1]
        if cmd == "set" then GDI.SurfaceSet(h, op[2], op[3], op[4], op[5], op[6])
        elseif cmd == "fill" then GDI.SurfaceFill(h, op[2], op[3], op[4], op[5], op[6], op[7], op[8])
        elseif cmd == "scroll" then GDI.SurfaceScroll(h, op[2])
        elseif cmd == "clear" then GDI.SurfaceClear(h, op[2], op[3]) end
    end
    return true
end

-- ═══ QUERIES ═══

function GDI.GetGpuCount() return #g_tGpus end

function GDI.GetGpuInfo(nIdx)
    local g = g_tGpus[nIdx]; if not g then return nil end
    return { address = g.address, screenAddr = g.screenAddr, nW = g.nW, nH = g.nH, nMaxW = g.nMaxW, nMaxH = g.nMaxH }
end

function GDI.GetSurfaceList()
    local t = {}
    for h, s in pairs(g_tSurfaces) do
        t[#t + 1] = {
            nHandle = h, nW = s.nW, nH = s.nH, nGpuTarget = s.nGpuTarget,
            nOwnerPid = s.nOwnerPid, bVisible = s.bVisible, nZOrder = s.nZOrder,
            sLabel = s.sLabel, nScreenX = s.nScreenX, nScreenY = s.nScreenY,
        }
    end
    return t
end

function GDI.GetRawGpu(nIdx) local g = g_tGpus[nIdx]; return g and g.proxy or nil end

-- ═══ SWAPCHAIN / CMD BUFFER / MULTI-GPU (delegated to fast-path) ═══

function GDI.CreateSwapchain(nGpuIdx, nW, nH)
    if g_tFastPath and g_tFastPath.fCreateSwapchain then
        local nDH, sErr = g_tFastPath.fCreateSwapchain(nGpuIdx, nW, nH)
        if not nDH then return nil, sErr end
        local h = g_nNextSwapHandle; g_nNextSwapHandle = g_nNextSwapHandle + 1
        g_tSwapchains[h] = { nGpuIdx = nGpuIdx, nDriverHandle = nDH }; return h
    end
    return nil, "GPU driver not attached"
end
function GDI.PresentSwapchain(h)
    local sc = g_tSwapchains[h]; if not sc then return nil end
    if g_tFastPath and g_tFastPath.fPresentSwapchain then return g_tFastPath.fPresentSwapchain(sc.nDriverHandle) end
end
function GDI.AcquireImage(h)
    local sc = g_tSwapchains[h]; if not sc then return nil end
    if g_tFastPath and g_tFastPath.fAcquireImage then return g_tFastPath.fAcquireImage(sc.nDriverHandle) end; return 0
end
function GDI.DestroySwapchain(h)
    local sc = g_tSwapchains[h]; if not sc then return end
    if g_tFastPath and g_tFastPath.fDestroySwapchain then g_tFastPath.fDestroySwapchain(sc.nDriverHandle) end
    g_tSwapchains[h] = nil
end

function GDI.CreateCmdBuffer(nGpuIdx)
    if g_tFastPath and g_tFastPath.fCreateCmdBuffer then
        local nDH = g_tFastPath.fCreateCmdBuffer(nGpuIdx or 1)
        local h = g_nNextCmdHandle; g_nNextCmdHandle = g_nNextCmdHandle + 1
        g_tCmdBuffers[h] = { nDriverHandle = nDH }; return h
    end
end
function GDI.BeginCmdBuffer(h) local cb = g_tCmdBuffers[h]; if cb and g_tFastPath then return g_tFastPath.fBeginCmdBuffer(cb.nDriverHandle) end end
function GDI.CmdSet(h, nX, nY, s, nFg, nBg) local cb = g_tCmdBuffers[h]; if cb and g_tFastPath then return g_tFastPath.fRecordCmd(cb.nDriverHandle, 1, nX, nY, s, nFg, nBg) end end
function GDI.CmdFill(h, nX, nY, nW, nH, c, nFg, nBg) local cb = g_tCmdBuffers[h]; if cb and g_tFastPath then return g_tFastPath.fRecordCmd(cb.nDriverHandle, 2, nX, nY, nW, nH, c, nFg, nBg) end end
function GDI.EndCmdBuffer(h) local cb = g_tCmdBuffers[h]; if cb and g_tFastPath then return g_tFastPath.fEndCmdBuffer(cb.nDriverHandle) end end
function GDI.SubmitCmdBuffer(h, f) local cb = g_tCmdBuffers[h]; if cb and g_tFastPath then return g_tFastPath.fSubmitCmdBuffer(cb.nDriverHandle, f) end end
function GDI.DestroyCmdBuffer(h) local cb = g_tCmdBuffers[h]; if cb and g_tFastPath then g_tFastPath.fDestroyCmdBuffer(cb.nDriverHandle) end; g_tCmdBuffers[h] = nil end

function GDI.MultiGpuDraw(tBatch)
    if not tBatch or #tBatch == 0 then return 0 end
    local n = 0
    for nGpuIdx, tGpu in pairs(g_tGpus) do
        if tGpu.screenAddr then
            if g_tFastPath and g_tFastPath.fFastRenderBatch then g_tFastPath.fFastRenderBatch(nGpuIdx, tBatch)
            else for _, t in ipairs(tBatch) do _gpuSet(nGpuIdx, t[1], t[2], t[3], t[4] or 0xFFFFFF, t[5] or 0x000000) end end
            n = n + 1
        end
    end
    return n
end

function GDI.GpuDraw(nGpuIdx, tBatch)
    if not tBatch or #tBatch == 0 then return 0 end
    if g_tFastPath and g_tFastPath.fFastRenderBatch then
        local _, nC = g_tFastPath.fFastRenderBatch(nGpuIdx, tBatch); return nC or #tBatch
    end
    for _, t in ipairs(tBatch) do _gpuSet(nGpuIdx, t[1], t[2], t[3], t[4] or 0xFFFFFF, t[5] or 0x000000) end
    return #tBatch
end

return GDI