-- /system/gdi.lua
-- Graphics Device Interface v2 — GPU-Accelerated Kernel Module
--
-- Architecture:
--   Two modes of operation:
--
--   DIRECT MODE (before GPU driver loads):
--     Uses raw_component GPU proxies with its own pipeline cache.
--     Active during early boot and if GPU driver never loads.
--
--   FAST-PATH MODE (after GPU driver registers):
--     Calls GPU driver functions directly via closure references.
--     Zero IRP dispatch, zero signal send, zero context switch.
--     The GPU driver's closures capture its adapter state as upvalues;
--     calling them from kernel context accesses that state transparently.
--
-- Features:
--   • Multi-GPU native support (GX_AX_multi_adapter)
--   • Swapchain commands (GX_AX_swapchain)
--   • Command buffers (GX_AX_cmd_buffer)
--   • Pipeline state cache (GX_AX_pipeline_state)
--   • Color-sorted batch compositor (no budget limit)
--   • Z-ordered surface compositing
--   • Multi-GPU broadcast drawing
--   • Input routing (keyboard focus per surface)
--

local GDI = {}

-- ═══════════════════════════════════════════
-- STATE
-- ═══════════════════════════════════════════

local g_tGpus           = {}   -- [idx] = { proxy, address, screenAddr, nW, nH, … }
local g_tScreens        = {}   -- [addr] = { address, gpuIdx }
local g_tSurfaces       = {}   -- [handle] = surface
local g_nNextHandle     = 1
local g_nFocusedSurface = nil
local g_tInputQueues    = {}   -- [handle] = { events… }
local g_tScreenBuf      = {}   -- [gpuIdx][y] = { sChars, tFg, tBg }
local g_fLog            = function() end
local g_nMaxZSeen       = 0

-- Pipeline state cache per GPU (tracks last-set fg/bg to skip redundant calls)
local g_tPipelineState  = {}   -- [gpuIdx] = { nLastFg, nLastBg }

-- GPU driver fast-path function table (nil until driver registers)
local g_tFastPath       = nil

-- Swapchain state
local g_tSwapchains     = {}   -- [handle] = swapchain info
local g_nNextSwapHandle = 1

-- Command buffer state
local g_tCmdBuffers     = {}   -- [handle] = command buffer info
local g_nNextCmdHandle  = 1

-- ═══════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════

local function _newRow(nW, nFg, nBg)
    nFg = nFg or 0xFFFFFF
    nBg = nBg or 0x000000
    local tFg, tBg = {}, {}
    for x = 1, nW do tFg[x] = nFg; tBg[x] = nBg end
    return {
        sChars = string.rep(" ", nW),
        tFg    = tFg,
        tBg    = tBg,
        bDirty = true,
    }
end

local function _clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- ═══════════════════════════════════════════
-- LOW-LEVEL GPU OPERATIONS
-- Pipeline-cached: skip setForeground/setBackground
-- when the color is already active on the GPU.
-- ═══════════════════════════════════════════

local function _gpuSetFg(nGpuIdx, nColor)
    local tPS = g_tPipelineState[nGpuIdx]
    if not tPS then return end
    if tPS.nLastFg == nColor then return end
    local tGpu = g_tGpus[nGpuIdx]
    if not tGpu or not tGpu.proxy then return end
    tGpu.proxy.setForeground(nColor)
    tPS.nLastFg = nColor
end

local function _gpuSetBg(nGpuIdx, nColor)
    local tPS = g_tPipelineState[nGpuIdx]
    if not tPS then return end
    if tPS.nLastBg == nColor then return end
    local tGpu = g_tGpus[nGpuIdx]
    if not tGpu or not tGpu.proxy then return end
    tGpu.proxy.setBackground(nColor)
    tPS.nLastBg = nColor
end

local function _gpuSet(nGpuIdx, nX, nY, sText, nFg, nBg)
    _gpuSetFg(nGpuIdx, nFg)
    _gpuSetBg(nGpuIdx, nBg)
    local tGpu = g_tGpus[nGpuIdx]
    if tGpu and tGpu.proxy then
        tGpu.proxy.set(nX, nY, sText)
    end
end

local function _gpuFill(nGpuIdx, nX, nY, nW, nH, sCh, nFg, nBg)
    _gpuSetFg(nGpuIdx, nFg)
    _gpuSetBg(nGpuIdx, nBg)
    local tGpu = g_tGpus[nGpuIdx]
    if tGpu and tGpu.proxy then
        tGpu.proxy.fill(nX, nY, nW, nH, sCh or " ")
    end
end

local function _gpuInvalidatePipeline(nGpuIdx)
    local tPS = g_tPipelineState[nGpuIdx]
    if tPS then tPS.nLastFg = -1; tPS.nLastBg = -1 end
end

-- ═══════════════════════════════════════════
-- INIT / GPU MANAGEMENT
-- ═══════════════════════════════════════════

function GDI.Initialize(tOpts)
    g_fLog = tOpts.fLog or g_fLog

    -- Enumerate GPUs
    local nIdx = 0
    for sAddr in raw_component.list("gpu") do
        nIdx = nIdx + 1
        g_tGpus[nIdx] = {
            address    = sAddr,
            proxy      = raw_component.proxy(sAddr),
            screenAddr = nil,
            nW = 0, nH = 0,
            nMaxW = 0, nMaxH = 0,
        }
        g_tPipelineState[nIdx] = { nLastFg = -1, nLastBg = -1 }
    end

    -- Enumerate screens
    local nScr = 0
    for sAddr in raw_component.list("screen") do
        nScr = nScr + 1
        g_tScreens[sAddr] = { address = sAddr, gpuIdx = nil }
    end

    -- Auto-bind: GPU N → Screen N
    local tScreenAddrs = {}
    for sAddr in pairs(g_tScreens) do
        tScreenAddrs[#tScreenAddrs + 1] = sAddr
    end
    table.sort(tScreenAddrs)
    for i, sAddr in ipairs(tScreenAddrs) do
        if g_tGpus[i] then GDI.BindGpu(i, sAddr) end
    end

    g_fLog(string.format("[GDI] v2 initialized: %d GPU(s), %d screen(s)", nIdx, nScr))
    return true
end

function GDI.BindGpu(nIdx, sScreenAddr)
    local tGpu = g_tGpus[nIdx]
    if not tGpu then return nil, "bad gpu index" end

    tGpu.proxy.bind(sScreenAddr)
    tGpu.screenAddr = sScreenAddr
    tGpu.nMaxW, tGpu.nMaxH = tGpu.proxy.maxResolution()
    tGpu.proxy.setResolution(tGpu.nMaxW, tGpu.nMaxH)
    tGpu.nW, tGpu.nH = tGpu.proxy.getResolution()

    -- Build screen buffer
    g_tScreenBuf[nIdx] = {}
    for y = 1, tGpu.nH do
        g_tScreenBuf[nIdx][y] = _newRow(tGpu.nW)
        g_tScreenBuf[nIdx][y].bDirty = false
    end

    -- Clear physical screen
    _gpuInvalidatePipeline(nIdx)
    _gpuFill(nIdx, 1, 1, tGpu.nW, tGpu.nH, " ", 0xFFFFFF, 0x000000)

    if g_tScreens[sScreenAddr] then
        g_tScreens[sScreenAddr].gpuIdx = nIdx
    end

    g_fLog(string.format("[GDI] GPU %d → %s (%dx%d)",
        nIdx, sScreenAddr:sub(1, 8), tGpu.nW, tGpu.nH))
    return true
end

-- ═══════════════════════════════════════════
-- GPU DRIVER FAST-PATH ATTACHMENT
-- Called by kernel when GPU driver registers.
-- Receives direct function references as closures.
-- ═══════════════════════════════════════════

function GDI.AttachGpuDriver(tFP)
    g_tFastPath = tFP
    g_fLog("[GDI] GPU driver fast-path attached")
    g_fLog(string.format("[GDI]   %d adapter(s) via driver",
        tFP.nAdapterCount or 0))
    return true
end

function GDI.HasGpuDriver()
    return g_tFastPath ~= nil
end

-- ═══════════════════════════════════════════
-- SURFACE LIFECYCLE
-- ═══════════════════════════════════════════

function GDI.CreateSurface(nW, nH, tOpts)
    tOpts = tOpts or {}
    local h = g_nNextHandle
    g_nNextHandle = g_nNextHandle + 1

    local tRows = {}
    for y = 1, nH do tRows[y] = _newRow(nW) end

    local nZ = tOpts.nZOrder or 0
    if nZ > g_nMaxZSeen then g_nMaxZSeen = nZ end

    g_tSurfaces[h] = {
        nHandle    = h,
        nW         = nW,
        nH         = nH,
        tRows      = tRows,
        nGpuTarget = tOpts.nGpuTarget or 1,
        nScreenX   = tOpts.nScreenX or 1,
        nScreenY   = tOpts.nScreenY or 1,
        nZOrder    = nZ,
        nOwnerPid  = tOpts.nOwnerPid or 0,
        bVisible   = tOpts.bVisible ~= false,
        sLabel     = tOpts.sLabel or "",
    }
    g_tInputQueues[h] = {}
    return h
end

function GDI.DestroySurface(h)
    g_tSurfaces[h] = nil
    g_tInputQueues[h] = nil
    if g_nFocusedSurface == h then g_nFocusedSurface = nil end
end

function GDI.ResizeSurface(h, nNewW, nNewH)
    local s = g_tSurfaces[h]
    if not s then return nil, "bad handle" end
    local tNewRows = {}
    for y = 1, nNewH do
        if y <= s.nH then
            local old = s.tRows[y]
            local r = _newRow(nNewW)
            local nCopy = math.min(s.nW, nNewW)
            r.sChars = old.sChars:sub(1, nCopy)
                     .. string.rep(" ", math.max(0, nNewW - nCopy))
            for x = 1, nCopy do
                r.tFg[x] = old.tFg[x]
                r.tBg[x] = old.tBg[x]
            end
            tNewRows[y] = r
        else
            tNewRows[y] = _newRow(nNewW)
        end
    end
    s.tRows = tNewRows
    s.nW = nNewW
    s.nH = nNewH
    return true
end

-- ═══════════════════════════════════════════
-- SURFACE DRAWING
-- ═══════════════════════════════════════════

function GDI.SurfaceSet(h, nX, nY, sText, nFg, nBg)
    local s = g_tSurfaces[h]
    if not s then return nil, "bad handle" end
    if nY < 1 or nY > s.nH then return true end

    local r = s.tRows[nY]
    local nLen = #sText

    -- Clamp left
    if nX < 1 then
        sText = sText:sub(2 - nX)
        nLen  = #sText
        nX    = 1
    end
    -- Clamp right
    if nX + nLen - 1 > s.nW then
        nLen  = s.nW - nX + 1
        sText = sText:sub(1, nLen)
    end
    if nLen <= 0 then return true end

    -- Splice character string
    r.sChars = r.sChars:sub(1, nX - 1)
              .. sText
              .. r.sChars:sub(nX + nLen)

    -- Colors
    if nFg then for i = nX, nX + nLen - 1 do r.tFg[i] = nFg end end
    if nBg then for i = nX, nX + nLen - 1 do r.tBg[i] = nBg end end

    r.bDirty = true
    return true
end

function GDI.SurfaceFill(h, nX, nY, nW, nH, sChar, nFg, nBg)
    local s = g_tSurfaces[h]
    if not s then return nil, "bad handle" end
    sChar = (sChar or " "):sub(1, 1)
    local sLine = string.rep(sChar, nW)
    for y = math.max(1, nY), math.min(s.nH, nY + nH - 1) do
        GDI.SurfaceSet(h, nX, y, sLine, nFg, nBg)
    end
    return true
end

function GDI.SurfaceScroll(h, nLines)
    local s = g_tSurfaces[h]
    if not s then return nil, "bad handle" end
    if nLines > 0 then
        for _ = 1, math.min(nLines, s.nH) do
            table.remove(s.tRows, 1)
            s.tRows[s.nH] = _newRow(s.nW)
        end
    elseif nLines < 0 then
        for _ = 1, math.min(-nLines, s.nH) do
            table.remove(s.tRows, s.nH)
            table.insert(s.tRows, 1, _newRow(s.nW))
        end
    end
    for y = 1, s.nH do s.tRows[y].bDirty = true end
    return true
end

function GDI.SurfaceClear(h, nFg, nBg)
    local s = g_tSurfaces[h]
    if not s then return nil, "bad handle" end
    for y = 1, s.nH do s.tRows[y] = _newRow(s.nW, nFg, nBg) end
    return true
end

function GDI.SurfaceSetVisible(h, b)
    local s = g_tSurfaces[h]
    if not s then return nil end
    if s.bVisible ~= b then
        s.bVisible = b
        for y = 1, s.nH do s.tRows[y].bDirty = true end
    end
    return true
end

function GDI.SurfaceSetPosition(h, nX, nY)
    local s = g_tSurfaces[h]
    if not s then return nil end
    if s.nScreenX ~= nX or s.nScreenY ~= nY then
        s.nScreenX = nX; s.nScreenY = nY
        for y = 1, s.nH do s.tRows[y].bDirty = true end
    end
    return true
end

function GDI.SurfaceSetZ(h, nZ)
    local s = g_tSurfaces[h]
    if not s then return nil end
    s.nZOrder = nZ
    if nZ > g_nMaxZSeen then g_nMaxZSeen = nZ end
    return true
end

function GDI.SurfaceBringToFront(h)
    g_nMaxZSeen = g_nMaxZSeen + 1
    return GDI.SurfaceSetZ(h, g_nMaxZSeen)
end

function GDI.SurfaceSetGpu(h, nGpuIdx)
    local s = g_tSurfaces[h]
    if not s then return nil end
    s.nGpuTarget = nGpuIdx
    for y = 1, s.nH do s.tRows[y].bDirty = true end
    return true
end

function GDI.SurfaceGetSize(h)
    local s = g_tSurfaces[h]
    if not s then return nil end
    return s.nW, s.nH
end

-- ═══════════════════════════════════════════
-- SWAPCHAIN (delegates to GPU driver fast-path)
-- ═══════════════════════════════════════════

function GDI.CreateSwapchain(nGpuIdx, nW, nH)
    if g_tFastPath and g_tFastPath.fCreateSwapchain then
        local nDriverHandle, sErr = g_tFastPath.fCreateSwapchain(nGpuIdx, nW, nH)
        if not nDriverHandle then return nil, sErr end
        local h = g_nNextSwapHandle
        g_nNextSwapHandle = g_nNextSwapHandle + 1
        g_tSwapchains[h] = {
            nGpuIdx = nGpuIdx,
            nDriverHandle = nDriverHandle,
        }
        return h
    end
    return nil, "GPU driver not attached (no swapchain support)"
end

function GDI.PresentSwapchain(h)
    local sc = g_tSwapchains[h]
    if not sc then return nil, "invalid swapchain" end
    if g_tFastPath and g_tFastPath.fPresentSwapchain then
        return g_tFastPath.fPresentSwapchain(sc.nDriverHandle)
    end
    return nil, "GPU driver not attached"
end

function GDI.AcquireImage(h)
    local sc = g_tSwapchains[h]
    if not sc then return nil end
    if g_tFastPath and g_tFastPath.fAcquireImage then
        return g_tFastPath.fAcquireImage(sc.nDriverHandle)
    end
    return 0
end

function GDI.DestroySwapchain(h)
    local sc = g_tSwapchains[h]
    if not sc then return end
    if g_tFastPath and g_tFastPath.fDestroySwapchain then
        g_tFastPath.fDestroySwapchain(sc.nDriverHandle)
    end
    g_tSwapchains[h] = nil
end

-- ═══════════════════════════════════════════
-- COMMAND BUFFER (delegates to GPU driver)
-- ═══════════════════════════════════════════

function GDI.CreateCmdBuffer(nGpuIdx)
    if g_tFastPath and g_tFastPath.fCreateCmdBuffer then
        local nDH = g_tFastPath.fCreateCmdBuffer(nGpuIdx or 1)
        local h = g_nNextCmdHandle
        g_nNextCmdHandle = g_nNextCmdHandle + 1
        g_tCmdBuffers[h] = { nDriverHandle = nDH }
        return h
    end
    return nil, "GPU driver not attached"
end

function GDI.BeginCmdBuffer(h)
    local cb = g_tCmdBuffers[h]
    if not cb then return nil end
    if g_tFastPath and g_tFastPath.fBeginCmdBuffer then
        return g_tFastPath.fBeginCmdBuffer(cb.nDriverHandle)
    end
end

function GDI.CmdSet(h, nX, nY, sText, nFg, nBg)
    local cb = g_tCmdBuffers[h]
    if not cb then return nil end
    if g_tFastPath and g_tFastPath.fRecordCmd then
        return g_tFastPath.fRecordCmd(cb.nDriverHandle, 1, nX, nY, sText, nFg, nBg)
    end
end

function GDI.CmdFill(h, nX, nY, nW, nH, sCh, nFg, nBg)
    local cb = g_tCmdBuffers[h]
    if not cb then return nil end
    if g_tFastPath and g_tFastPath.fRecordCmd then
        return g_tFastPath.fRecordCmd(cb.nDriverHandle, 2, nX, nY, nW, nH, sCh, nFg, nBg)
    end
end

function GDI.EndCmdBuffer(h)
    local cb = g_tCmdBuffers[h]
    if not cb then return nil end
    if g_tFastPath and g_tFastPath.fEndCmdBuffer then
        return g_tFastPath.fEndCmdBuffer(cb.nDriverHandle)
    end
end

function GDI.SubmitCmdBuffer(h, nFenceHandle)
    local cb = g_tCmdBuffers[h]
    if not cb then return nil end
    if g_tFastPath and g_tFastPath.fSubmitCmdBuffer then
        return g_tFastPath.fSubmitCmdBuffer(cb.nDriverHandle, nFenceHandle)
    end
end

function GDI.DestroyCmdBuffer(h)
    local cb = g_tCmdBuffers[h]
    if not cb then return end
    if g_tFastPath and g_tFastPath.fDestroyCmdBuffer then
        g_tFastPath.fDestroyCmdBuffer(cb.nDriverHandle)
    end
    g_tCmdBuffers[h] = nil
end

-- ═══════════════════════════════════════════
-- MULTI-GPU BROADCAST DRAWING
-- Sends the same batch of draw operations to ALL bound GPUs.
-- Not implemented in gpu.sys.lua (single-adapter only),
-- so we implement it here as a GDI-level extension.
--
-- Usage via syscall:
--   syscall("gdi_multi_gpu_draw", tBatch)
--   where tBatch = {{x, y, text, fg, bg}, ...}
-- ═══════════════════════════════════════════

function GDI.MultiGpuDraw(tBatch)
    if not tBatch or #tBatch == 0 then return 0 end

    local nGpusDone = 0

    for nGpuIdx, tGpu in pairs(g_tGpus) do
        if not tGpu.screenAddr then goto nextBroadcastGpu end

        -- Use fast-path render_batch if GPU driver is attached
        if g_tFastPath and g_tFastPath.fFastRenderBatch then
            g_tFastPath.fFastRenderBatch(nGpuIdx, tBatch)
            nGpusDone = nGpusDone + 1
        else
            -- Direct mode: iterate batch with pipeline cache
            for _, t in ipairs(tBatch) do
                _gpuSet(nGpuIdx, t[1], t[2], t[3], t[4] or 0xFFFFFF, t[5] or 0x000000)
            end
            nGpusDone = nGpusDone + 1
        end

        ::nextBroadcastGpu::
    end

    return nGpusDone
end

-- Single-GPU targeted draw (for when you want a specific adapter)
function GDI.GpuDraw(nGpuIdx, tBatch)
    if not tBatch or #tBatch == 0 then return 0 end

    if g_tFastPath and g_tFastPath.fFastRenderBatch then
        local bOk, nCount = g_tFastPath.fFastRenderBatch(nGpuIdx, tBatch)
        return nCount or #tBatch
    end

    for _, t in ipairs(tBatch) do
        _gpuSet(nGpuIdx, t[1], t[2], t[3], t[4] or 0xFFFFFF, t[5] or 0x000000)
    end
    return #tBatch
end

-- ═══════════════════════════════════════════
-- COMPOSITOR — Color-Sorted Batch Rendering
--
-- Algorithm:
--   1. Collect visible surfaces per GPU, z-sorted
--   2. Walk dirty surface rows, diff against screen buffer
--   3. Collect changed cells into a batch
--   4. Sort batch by (fg, bg) to minimize color changes
--   5. Group consecutive same-color cells into text runs
--   6. Send to GPU with pipeline state cache
--   7. Update screen buffer
--
-- No budget limiting — everything is flushed each call.
-- ═══════════════════════════════════════════

function GDI.Composite()
    local nTotalCalls = 0

    for nGpuIdx, tGpu in pairs(g_tGpus) do
        if not tGpu.screenAddr then goto nextGpu end
        local oGpu   = tGpu.proxy
        local tSBuf  = g_tScreenBuf[nGpuIdx]
        if not tSBuf then goto nextGpu end

        -- Collect visible surfaces for this GPU, z-sorted
        local tVis = {}
        for _, s in pairs(g_tSurfaces) do
            if s.bVisible and s.nGpuTarget == nGpuIdx then
                tVis[#tVis + 1] = s
            end
        end
        table.sort(tVis, function(a, b) return a.nZOrder < b.nZOrder end)

        -- Phase 1: Build batch of changed cells
        local tBatch = {}
        local nBatch = 0

        for _, s in ipairs(tVis) do
            for sy = 1, s.nH do
                local r = s.tRows[sy]
                if not r.bDirty then goto nextSRow end

                local nPhysY = s.nScreenY + sy - 1
                if nPhysY < 1 or nPhysY > tGpu.nH then goto nextSRow end
                local tScr = tSBuf[nPhysY]

                -- Walk row, find cells that differ from screen buffer
                for x = 1, s.nW do
                    local nPhysX = s.nScreenX + x - 1
                    if nPhysX < 1 or nPhysX > tGpu.nW then goto nextCell end

                    local nFg = r.tFg[x]
                    local nBg = r.tBg[x]
                    local sCh = r.sChars:sub(x, x)

                    -- Diff against screen buffer
                    local sOldCh = tScr.sChars:sub(nPhysX, nPhysX)
                    local nOldFg = tScr.tFg[nPhysX]
                    local nOldBg = tScr.tBg[nPhysX]

                    if sCh ~= sOldCh or nFg ~= nOldFg or nBg ~= nOldBg then
                        nBatch = nBatch + 1
                        tBatch[nBatch] = { nPhysX, nPhysY, sCh, nFg, nBg }

                        -- Update screen buffer immediately
                        tScr.sChars = tScr.sChars:sub(1, nPhysX - 1)
                                    .. sCh
                                    .. tScr.sChars:sub(nPhysX + 1)
                        tScr.tFg[nPhysX] = nFg
                        tScr.tBg[nPhysX] = nBg
                    end

                    ::nextCell::
                end

                r.bDirty = false
                ::nextSRow::
            end
        end

        if nBatch == 0 then goto nextGpu end

        -- Phase 2: Sort batch by color (fg * 0x1000000 + bg)
        table.sort(tBatch, function(a, b)
            local ka = a[4] * 0x1000000 + a[5]
            local kb = b[4] * 0x1000000 + b[5]
            if ka ~= kb then return ka < kb end
            -- Same color: sort by position for run grouping
            if a[2] ~= b[2] then return a[2] < b[2] end
            return a[1] < b[1]
        end)

        -- Phase 3: Group into text runs and send to GPU
        -- Use GPU driver fast path if available
        if g_tFastPath and g_tFastPath.fFastRenderBatch then
            g_tFastPath.fFastRenderBatch(nGpuIdx, tBatch)
            nTotalCalls = nTotalCalls + nBatch
        else
            -- Direct mode with pipeline cache and run grouping
            local i = 1
            while i <= nBatch do
                local t = tBatch[i]
                local nFg, nBg = t[4], t[5]

                -- Find run of consecutive same-color cells on the same row
                local nRunStart = i
                local tChars = { t[3] }
                local nRunX = t[1]
                local nRunY = t[2]
                local nExpectX = nRunX + 1

                i = i + 1
                while i <= nBatch do
                    local tn = tBatch[i]
                    if tn[4] ~= nFg or tn[5] ~= nBg then break end
                    if tn[2] ~= nRunY or tn[1] ~= nExpectX then break end
                    tChars[#tChars + 1] = tn[3]
                    nExpectX = nExpectX + 1
                    i = i + 1
                end

                -- Emit the grouped run
                _gpuSetFg(nGpuIdx, nFg)
                _gpuSetBg(nGpuIdx, nBg)
                oGpu.set(nRunX, nRunY, table.concat(tChars))
                nTotalCalls = nTotalCalls + 1
            end
        end

        ::nextGpu::
    end
    return nTotalCalls
end

-- Force every row dirty (e.g. after GPU rebind or theme change)
function GDI.ForceFullRedraw()
    for _, s in pairs(g_tSurfaces) do
        for y = 1, s.nH do s.tRows[y].bDirty = true end
    end
end

-- ═══════════════════════════════════════════
-- INPUT ROUTING
-- ═══════════════════════════════════════════

function GDI.SetFocus(h)
    g_nFocusedSurface = h
end

function GDI.GetFocus()
    return g_nFocusedSurface
end

function GDI.PushInput(h, tEvent)
    local q = g_tInputQueues[h]
    if not q then return nil end
    q[#q + 1] = tEvent
    return true
end

function GDI.PopInput(h)
    local q = g_tInputQueues[h]
    if not q or #q == 0 then return nil end
    return table.remove(q, 1)
end

function GDI.InputQueueSize(h)
    local q = g_tInputQueues[h]
    return q and #q or 0
end

-- Called by kernel keyboard signal handler
function GDI.OnKeyEvent(sType, sKbAddr, nChar, nCode, sPlayer)
    if not g_nFocusedSurface then return end
    GDI.PushInput(g_nFocusedSurface, {
        sType   = sType,
        nChar   = nChar,
        nCode   = nCode,
        sPlayer = sPlayer,
    })
end

-- ═══════════════════════════════════════════
-- BATCH SUBMIT (atomic multi-op)
-- ═══════════════════════════════════════════

function GDI.BatchSubmit(h, tOps)
    for _, op in ipairs(tOps) do
        local cmd = op[1]
        if cmd == "set" then
            GDI.SurfaceSet(h, op[2], op[3], op[4], op[5], op[6])
        elseif cmd == "fill" then
            GDI.SurfaceFill(h, op[2], op[3], op[4], op[5], op[6], op[7], op[8])
        elseif cmd == "scroll" then
            GDI.SurfaceScroll(h, op[2])
        elseif cmd == "clear" then
            GDI.SurfaceClear(h, op[2], op[3])
        end
    end
    return true
end

-- ═══════════════════════════════════════════
-- QUERIES
-- ═══════════════════════════════════════════

function GDI.GetGpuCount() return #g_tGpus end

function GDI.GetGpuInfo(nIdx)
    local g = g_tGpus[nIdx]
    if not g then return nil end
    return {
        address    = g.address,
        screenAddr = g.screenAddr,
        nW = g.nW, nH = g.nH,
        nMaxW = g.nMaxW, nMaxH = g.nMaxH,
    }
end

function GDI.GetSurfaceList()
    local t = {}
    for h, s in pairs(g_tSurfaces) do
        t[#t + 1] = {
            nHandle    = h,
            nW = s.nW, nH = s.nH,
            nGpuTarget = s.nGpuTarget,
            nOwnerPid  = s.nOwnerPid,
            bVisible   = s.bVisible,
            nZOrder    = s.nZOrder,
            sLabel     = s.sLabel,
            nScreenX   = s.nScreenX,
            nScreenY   = s.nScreenY,
        }
    end
    return t
end

function GDI.GetRawGpu(nIdx)
    local g = g_tGpus[nIdx]
    return g and g.proxy or nil
end

return GDI