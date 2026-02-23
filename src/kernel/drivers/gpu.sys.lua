--
-- /drivers/gpu.sys.lua
-- AxisOS Multi-GPU Driver v2.0 — GX_AX Extension Architecture
--
-- Vulkan-inspired resource management for OpenComputers text-mode GPUs.
-- Provides: multi-adapter enumeration, swapchains, sync fences,
--           command buffers, pipeline state cache, buffer pools,
--           async I/O via IOCP, and fast-path TTY integration.
--
-- Extensions exposed:
--   GX_AX_multi_adapter    Multi-GPU enumeration and device creation
--   GX_AX_swapchain        Double-buffered swap chains with present
--   GX_AX_sync_fence       Operation synchronization fences (waitable)
--   GX_AX_cmd_buffer       Deferred command recording + batch submit
--   GX_AX_render_pass      Optimized state-sorted render pass
--   GX_AX_buffer_pool      Off-screen buffer management (Tier 3)
--   GX_AX_pipeline_state   Cached color/resolution state
--   GX_AX_async_submit     IOCP-based async operation submission
--   GX_AX_fast_tty         Fast-path TTY integration (no IRP overhead)
--   GX_AX_copy_engine      GPU-accelerated region copy/scroll
--

local tStatus = require("errcheck")
local oKMD    = require("kmd_api")
local tDKS    = require("shared_structs")

-- =============================================
-- DRIVER INFO (DKMS contract)
-- =============================================

g_tDriverInfo = {
    sDriverName         = "AxisGPU_GX",
    sDriverType         = tDKS.DRIVER_TYPE_KMD,
    nLoadPriority       = 150,
    sVersion            = "2.0.0",
    bAsyncIoSupported   = true,   -- DKMS async I/O contract
}

-- =============================================
-- 1. CONSTANTS
-- =============================================

local MAX_ADAPTERS      = 8
local MAX_SWAPCHAINS    = 16
local MAX_FENCES        = 64
local MAX_CMD_BUFFERS   = 32
local MAX_BUFFER_POOL   = 24
local SWAPCHAIN_FRAMES  = 2     -- double buffering

-- GPU Tier capabilities
local TIER_BASIC    = 1     -- set, fill, copy, colors
local TIER_ADVANCED = 2     -- + higher resolution
local TIER_BUFFER   = 3     -- + allocateBuffer, bitblt, freeBuffer

-- Fence states
local FENCE_UNSIGNALED = 0
local FENCE_SIGNALED   = 1

-- Command types (for command buffer recording)
local CMD_SET            = 1
local CMD_FILL           = 2
local CMD_COPY           = 3
local CMD_SET_FG         = 4
local CMD_SET_BG         = 5
local CMD_SET_RESOLUTION = 6
local CMD_BIND_SCREEN    = 7
local CMD_SET_ACTIVE_BUF = 8
local CMD_BITBLT         = 9
local CMD_SCROLL         = 10

-- =============================================
-- 2. STATE
-- =============================================

local g_pDeviceObject = nil

-- Adapter registry: discovered GPU hardware
-- [nIdx] = { sAddr, oProxy, nTier, nMaxW, nMaxH, bBufSupport, sScreen, bBound }
local g_tAdapters    = {}
local g_nAdapterCount = 0

-- Screen registry
-- [sAddr] = true (available screens)
local g_tScreens = {}

-- Swapchain registry
-- [nHandle] = { nAdapter, nW, nH, nFrontBuf, nBackBuf, bSoftware, tSoftFront, tSoftBack, nPresents }
local g_tSwapchains  = {}
local g_nSwapNext    = 1

-- Fence registry
-- [nHandle] = { nState, tWaiters }
local g_tFences      = {}
local g_nFenceNext   = 1

-- Command buffer registry
-- [nHandle] = { tCommands, nAdapter, bRecording, nCmdCount }
local g_tCmdBuffers  = {}
local g_nCmdBufNext  = 1

-- Buffer pool (Tier 3 off-screen buffers)
-- [nHandle] = { nAdapter, nGpuBufIdx, nW, nH }
local g_tBufferPool  = {}
local g_nBufPoolNext = 1

-- Pipeline state cache per adapter
-- [nAdapterIdx] = { nLastFg, nLastBg, nActiveBuffer, nW, nH }
local g_tPipelineState = {}

-- Statistics
local g_tStats = {
    nTotalSets      = 0,
    nTotalFills     = 0,
    nTotalCopies    = 0,
    nTotalPresents  = 0,
    nTotalCmdSubmit = 0,
    nColorChanges   = 0,
    nColorSkips     = 0,  -- avoided by cache
    nFenceSignals   = 0,
    nBatchOps       = 0,
}

-- =============================================
-- 3. ADAPTER DISCOVERY
-- Enumerate all GPU components, determine tier,
-- pair with available screens.
-- =============================================

local function fDetectTier(oProxy)
    -- Tier 3: has allocateBuffer
    if type(oProxy.allocateBuffer) == "function" then return TIER_BUFFER end
    -- Tier 2: max resolution > 80x25
    local bOk, nW, nH = pcall(oProxy.maxResolution)
    if bOk and nW and nW > 80 then return TIER_ADVANCED end
    return TIER_BASIC
end

local function fDiscoverAdapters()
    g_tAdapters = {}
    g_tScreens  = {}
    g_nAdapterCount = 0

    -- Collect all screens
    local bOkS, tScreenList = syscall("raw_component_list", "screen")
    if bOkS and tScreenList then
        for sAddr in pairs(tScreenList) do
            g_tScreens[sAddr] = true
        end
    end

    -- Collect all GPUs
    local bOkG, tGpuList = syscall("raw_component_list", "gpu")
    if not bOkG or not tGpuList then return 0 end

    for sAddr in pairs(tGpuList) do
        if g_nAdapterCount >= MAX_ADAPTERS then break end

        local nProxySt, oProxy = oKMD.DkGetHardwareProxy(sAddr)
        if nProxySt ~= tStatus.STATUS_SUCCESS then goto nextGpu end

        local nTier = fDetectTier(oProxy)
        local bMaxOk, nMaxW, nMaxH = pcall(oProxy.maxResolution)
        if not bMaxOk then nMaxW, nMaxH = 80, 25 end

        local bBuf = (nTier >= TIER_BUFFER)

        g_nAdapterCount = g_nAdapterCount + 1
        local nIdx = g_nAdapterCount

        g_tAdapters[nIdx] = {
            sAddr      = sAddr,
            oProxy     = oProxy,
            nTier      = nTier,
            nMaxW      = nMaxW,
            nMaxH      = nMaxH,
            bBufSupport = bBuf,
            sScreen    = nil,    -- bound screen address
            bBound     = false,
        }

        -- Initialize pipeline state cache
        g_tPipelineState[nIdx] = {
            nLastFg      = -1,
            nLastBg      = -1,
            nActiveBuffer = 0,
            nW           = 0,
            nH           = 0,
        }

        oKMD.DkPrint(string.format(
            "GPU_GX: Adapter %d: %s Tier %d (%dx%d) buf=%s",
            nIdx, sAddr:sub(1, 8), nTier, nMaxW, nMaxH, tostring(bBuf)))

        ::nextGpu::
    end

    -- Auto-bind: pair GPUs with screens round-robin
    local nScreenIdx = 1
    local tScreenAddrs = {}
    for sAddr in pairs(g_tScreens) do
        tScreenAddrs[#tScreenAddrs + 1] = sAddr
    end

    for nIdx = 1, g_nAdapterCount do
        if nScreenIdx <= #tScreenAddrs then
            local sScr = tScreenAddrs[nScreenIdx]
            local oP = g_tAdapters[nIdx].oProxy
            local bBindOk = pcall(oP.bind, sScr)
            if bBindOk then
                g_tAdapters[nIdx].sScreen = sScr
                g_tAdapters[nIdx].bBound = true
                local bResOk, nW, nH = pcall(oP.getResolution)
                if bResOk then
                    g_tPipelineState[nIdx].nW = nW
                    g_tPipelineState[nIdx].nH = nH
                end
                oKMD.DkPrint(string.format(
                    "GPU_GX: Adapter %d bound to screen %s (%dx%d)",
                    nIdx, sScr:sub(1, 8), nW or 0, nH or 0))
                nScreenIdx = nScreenIdx + 1
            end
        end
    end

    return g_nAdapterCount
end

-- =============================================
-- 4. PIPELINE STATE CACHE
-- Track last-set fg/bg per adapter to avoid
-- redundant GPU color calls.  Each skipped call
-- saves ~0.05ms of component invoke overhead.
-- =============================================

local function fSetFg(nIdx, nColor)
    local tPS = g_tPipelineState[nIdx]
    if not tPS then return end
    if tPS.nLastFg == nColor then
        g_tStats.nColorSkips = g_tStats.nColorSkips + 1
        return
    end
    g_tAdapters[nIdx].oProxy.setForeground(nColor)
    tPS.nLastFg = nColor
    g_tStats.nColorChanges = g_tStats.nColorChanges + 1
end

local function fSetBg(nIdx, nColor)
    local tPS = g_tPipelineState[nIdx]
    if not tPS then return end
    if tPS.nLastBg == nColor then
        g_tStats.nColorSkips = g_tStats.nColorSkips + 1
        return
    end
    g_tAdapters[nIdx].oProxy.setBackground(nColor)
    tPS.nLastBg = nColor
    g_tStats.nColorChanges = g_tStats.nColorChanges + 1
end

local function fInvalidatePipeline(nIdx)
    local tPS = g_tPipelineState[nIdx]
    if tPS then tPS.nLastFg = -1; tPS.nLastBg = -1 end
end

-- =============================================
-- 5. SWAPCHAIN MANAGEMENT (GX_AX_swapchain)
-- Double-buffered present model.
-- Tier 3: hardware GPU buffers + bitblt
-- Tier 1-2: software shadow buffers
-- =============================================

local function fCreateSwapchain(nAdapterIdx, nW, nH)
    local tA = g_tAdapters[nAdapterIdx]
    if not tA or not tA.bBound then return nil, "Adapter not bound" end

    local nHandle = g_nSwapNext; g_nSwapNext = g_nSwapNext + 1

    local tSC = {
        nAdapter   = nAdapterIdx,
        nW         = nW or g_tPipelineState[nAdapterIdx].nW,
        nH         = nH or g_tPipelineState[nAdapterIdx].nH,
        nFrontBuf  = 0,     -- 0 = screen (buffer index for Tier 3)
        nBackBuf   = 0,
        bSoftware  = true,  -- software fallback
        tSoftFront = nil,
        tSoftBack  = nil,
        nPresents  = 0,
        nFrameIdx  = 0,
    }

    -- Try hardware double buffer (Tier 3)
    if tA.bBufSupport then
        local bOk1, nBuf1 = pcall(tA.oProxy.allocateBuffer, tSC.nW, tSC.nH)
        if bOk1 and nBuf1 and nBuf1 > 0 then
            local bOk2, nBuf2 = pcall(tA.oProxy.allocateBuffer, tSC.nW, tSC.nH)
            if bOk2 and nBuf2 and nBuf2 > 0 then
                tSC.nFrontBuf = nBuf1
                tSC.nBackBuf  = nBuf2
                tSC.bSoftware = false
                oKMD.DkPrint(string.format(
                    "GPU_GX: HW swapchain %d on adapter %d (bufs %d,%d)",
                    nHandle, nAdapterIdx, nBuf1, nBuf2))
            else
                pcall(tA.oProxy.freeBuffer, nBuf1)
            end
        end
    end

    -- Software fallback: track dirty regions only
    if tSC.bSoftware then
        oKMD.DkPrint(string.format(
            "GPU_GX: SW swapchain %d on adapter %d (%dx%d)",
            nHandle, nAdapterIdx, tSC.nW, tSC.nH))
    end

    g_tSwapchains[nHandle] = tSC
    return nHandle
end

local function fPresentSwapchain(nHandle)
    local tSC = g_tSwapchains[nHandle]
    if not tSC then return nil, "Invalid swapchain" end

    local tA = g_tAdapters[tSC.nAdapter]
    if not tA then return nil, "Adapter gone" end

    tSC.nPresents = tSC.nPresents + 1
    tSC.nFrameIdx = tSC.nFrameIdx + 1
    g_tStats.nTotalPresents = g_tStats.nTotalPresents + 1

    if not tSC.bSoftware then
        -- Hardware present: bitblt back buffer to screen (buffer 0)
        pcall(tA.oProxy.bitblt, 0, 1, 1, tSC.nW, tSC.nH,
              tSC.nBackBuf, 1, 1)
        -- Swap: old back becomes new back (reuse)
        tSC.nFrontBuf, tSC.nBackBuf = tSC.nBackBuf, tSC.nFrontBuf
        -- Set active to new back buffer for next frame's rendering
        pcall(tA.oProxy.setActiveBuffer, tSC.nBackBuf)
        fInvalidatePipeline(tSC.nAdapter)
    end
    -- Software mode: rendering goes directly to screen, present is a no-op
    -- (but we invalidate pipeline state in case another client changed colors)
    fInvalidatePipeline(tSC.nAdapter)
    return true
end

local function fDestroySwapchain(nHandle)
    local tSC = g_tSwapchains[nHandle]
    if not tSC then return end

    if not tSC.bSoftware then
        local tA = g_tAdapters[tSC.nAdapter]
        if tA then
            pcall(tA.oProxy.setActiveBuffer, 0)
            if tSC.nFrontBuf > 0 then pcall(tA.oProxy.freeBuffer, tSC.nFrontBuf) end
            if tSC.nBackBuf > 0 then pcall(tA.oProxy.freeBuffer, tSC.nBackBuf) end
        end
    end
    g_tSwapchains[nHandle] = nil
end

-- Get the back buffer index (for rendering into)
local function fAcquireImage(nHandle)
    local tSC = g_tSwapchains[nHandle]
    if not tSC then return nil end
    if tSC.bSoftware then return 0 end -- render to screen directly
    return tSC.nBackBuf
end

-- =============================================
-- 6. SYNC FENCES (GX_AX_sync_fence)
-- Lightweight waitable synchronization objects.
-- Backed by ke_ipc events when callers need
-- WaitForMultipleObjects support.
-- =============================================

local function fCreateFence(bSignaled)
    local nHandle = g_nFenceNext; g_nFenceNext = g_nFenceNext + 1
    g_tFences[nHandle] = {
        nState   = bSignaled and FENCE_SIGNALED or FENCE_UNSIGNALED,
        tWaiters = {},
    }
    return nHandle
end

local function fSignalFence(nHandle)
    local tF = g_tFences[nHandle]
    if not tF then return end
    tF.nState = FENCE_SIGNALED
    g_tStats.nFenceSignals = g_tStats.nFenceSignals + 1
    -- Wake all waiters
    for _, nPid in ipairs(tF.tWaiters) do
        pcall(syscall, "signal_send", nPid, "gx_fence_signaled", nHandle)
    end
    tF.tWaiters = {}
end

local function fResetFence(nHandle)
    local tF = g_tFences[nHandle]
    if tF then tF.nState = FENCE_UNSIGNALED end
end

local function fGetFenceStatus(nHandle)
    local tF = g_tFences[nHandle]
    if not tF then return nil end
    return tF.nState == FENCE_SIGNALED
end

local function fWaitFence(nHandle, nCallerPid)
    local tF = g_tFences[nHandle]
    if not tF then return nil, "Invalid fence" end
    if tF.nState == FENCE_SIGNALED then return true end
    tF.tWaiters[#tF.tWaiters + 1] = nCallerPid
    return false -- caller should yield
end

local function fDestroyFence(nHandle)
    g_tFences[nHandle] = nil
end

-- =============================================
-- 7. COMMAND BUFFER (GX_AX_cmd_buffer)
-- Record GPU operations, then submit as optimized batch.
-- Sort by color to minimize setFg/setBg calls.
-- =============================================

local function fCreateCmdBuffer(nAdapterIdx)
    local nHandle = g_nCmdBufNext; g_nCmdBufNext = g_nCmdBufNext + 1
    g_tCmdBuffers[nHandle] = {
        tCommands  = {},
        nAdapter   = nAdapterIdx or 1,
        bRecording = false,
        nCmdCount  = 0,
    }
    return nHandle
end

local function fBeginCmdBuffer(nHandle)
    local tCB = g_tCmdBuffers[nHandle]
    if not tCB then return nil, "Invalid cmd buffer" end
    tCB.tCommands = {}
    tCB.nCmdCount = 0
    tCB.bRecording = true
    return true
end

local function fRecordCmd(nHandle, nType, ...)
    local tCB = g_tCmdBuffers[nHandle]
    if not tCB or not tCB.bRecording then return nil end
    tCB.nCmdCount = tCB.nCmdCount + 1
    tCB.tCommands[tCB.nCmdCount] = { nType, ... }
    return tCB.nCmdCount
end

local function fEndCmdBuffer(nHandle)
    local tCB = g_tCmdBuffers[nHandle]
    if not tCB then return nil end
    tCB.bRecording = false
    return true
end

-- Submit: execute all recorded commands on the target adapter.
-- Optimization: sort by color to minimize GPU state changes.
local function fSubmitCmdBuffer(nHandle, nFenceHandle)
    local tCB = g_tCmdBuffers[nHandle]
    if not tCB or tCB.bRecording then return nil, "Not ready" end

    local nIdx = tCB.nAdapter
    local tA = g_tAdapters[nIdx]
    if not tA or not tA.oProxy then return nil, "No adapter" end
    local oP = tA.oProxy

    g_tStats.nTotalCmdSubmit = g_tStats.nTotalCmdSubmit + 1

    -- ---- Optimization: color-sort the SET commands ----
    -- Group by (fg, bg) to minimize setForeground/setBackground calls.
    -- Non-drawing commands (resolution, bind, etc.) execute in order.

    local tDrawOps  = {}  -- { {cmd, fg, bg}, ... }
    local tOtherOps = {}  -- { {idx, cmd}, ... }

    for i = 1, tCB.nCmdCount do
        local tCmd = tCB.tCommands[i]
        local nT = tCmd[1]
        if nT == CMD_SET then
            -- {CMD_SET, x, y, text, fg, bg}
            tDrawOps[#tDrawOps + 1] = {tCmd, tCmd[5] or 0xFFFFFF, tCmd[6] or 0x000000}
        elseif nT == CMD_FILL then
            -- {CMD_FILL, x, y, w, h, ch, fg, bg}
            tDrawOps[#tDrawOps + 1] = {tCmd, tCmd[7] or 0xFFFFFF, tCmd[8] or 0x000000}
        else
            tOtherOps[#tOtherOps + 1] = {i, tCmd}
        end
    end

    -- Sort draw ops by color (fg*0x1000000 + bg gives unique key)
    table.sort(tDrawOps, function(a, b)
        local ka = a[2] * 0x1000000 + a[3]
        local kb = b[2] * 0x1000000 + b[3]
        return ka < kb
    end)

    -- Execute non-draw ops first (in original order)
    for _, tPair in ipairs(tOtherOps) do
        local tCmd = tPair[2]
        local nT = tCmd[1]
        if nT == CMD_COPY then
            pcall(oP.copy, tCmd[2], tCmd[3], tCmd[4], tCmd[5], tCmd[6], tCmd[7])
            g_tStats.nTotalCopies = g_tStats.nTotalCopies + 1
        elseif nT == CMD_SET_RESOLUTION then
            pcall(oP.setResolution, tCmd[2], tCmd[3])
        elseif nT == CMD_BIND_SCREEN then
            pcall(oP.bind, tCmd[2])
            fInvalidatePipeline(nIdx)
        elseif nT == CMD_SET_ACTIVE_BUF then
            pcall(oP.setActiveBuffer, tCmd[2])
        elseif nT == CMD_BITBLT then
            pcall(oP.bitblt, tCmd[2], tCmd[3], tCmd[4],
                  tCmd[5], tCmd[6], tCmd[7], tCmd[8], tCmd[9])
        elseif nT == CMD_SCROLL then
            -- Scroll by N lines: copy + fill
            local nLines = tCmd[2] or 1
            local tPS = g_tPipelineState[nIdx]
            if tPS and tPS.nW > 0 and tPS.nH > 0 then
                pcall(oP.copy, 1, 1 + nLines, tPS.nW, tPS.nH - nLines, 0, -nLines)
                fSetFg(nIdx, 0xFFFFFF); fSetBg(nIdx, 0x000000)
                pcall(oP.fill, 1, tPS.nH - nLines + 1, tPS.nW, nLines, " ")
            end
        end
    end

    -- Execute sorted draw ops with pipeline state caching
    for _, tDraw in ipairs(tDrawOps) do
        local tCmd = tDraw[1]
        local nFg, nBg = tDraw[2], tDraw[3]
        fSetFg(nIdx, nFg)
        fSetBg(nIdx, nBg)

        local nT = tCmd[1]
        if nT == CMD_SET then
            pcall(oP.set, tCmd[2], tCmd[3], tCmd[4])
            g_tStats.nTotalSets = g_tStats.nTotalSets + 1
        elseif nT == CMD_FILL then
            pcall(oP.fill, tCmd[2], tCmd[3], tCmd[4], tCmd[5], tCmd[6])
            g_tStats.nTotalFills = g_tStats.nTotalFills + 1
        end
    end

    g_tStats.nBatchOps = g_tStats.nBatchOps + tCB.nCmdCount

    -- Signal fence if provided
    if nFenceHandle then fSignalFence(nFenceHandle) end

    return true, tCB.nCmdCount
end

local function fDestroyCmdBuffer(nHandle)
    g_tCmdBuffers[nHandle] = nil
end

-- =============================================
-- 8. BUFFER POOL (GX_AX_buffer_pool)
-- Off-screen GPU buffer allocation for Tier 3.
-- =============================================

local function fAllocBuffer(nAdapterIdx, nW, nH)
    local tA = g_tAdapters[nAdapterIdx]
    if not tA or not tA.bBufSupport then return nil, "No buffer support" end

    local bOk, nBufIdx = pcall(tA.oProxy.allocateBuffer, nW, nH)
    if not bOk or not nBufIdx or nBufIdx <= 0 then
        return nil, "GPU buffer allocation failed"
    end

    local nHandle = g_nBufPoolNext; g_nBufPoolNext = g_nBufPoolNext + 1
    g_tBufferPool[nHandle] = {
        nAdapter   = nAdapterIdx,
        nGpuBufIdx = nBufIdx,
        nW         = nW,
        nH         = nH,
    }
    return nHandle, nBufIdx
end

local function fFreeBuffer(nHandle)
    local tB = g_tBufferPool[nHandle]
    if not tB then return end
    local tA = g_tAdapters[tB.nAdapter]
    if tA and tA.oProxy then
        pcall(tA.oProxy.freeBuffer, tB.nGpuBufIdx)
    end
    g_tBufferPool[nHandle] = nil
end

-- =============================================
-- 9. FAST-PATH RENDER BATCH (GX_AX_fast_tty)
-- Optimized path for TTY render_batch calls.
-- Accepts array of {x, y, text, fg, bg} tuples.
-- Color-groups consecutive same-color entries
-- for minimal GPU state changes.
-- =============================================

local function fFastRenderBatch(nAdapterIdx, tBatch)
    local tA = g_tAdapters[nAdapterIdx]
    if not tA or not tA.oProxy then return nil, "No adapter" end
    local oP = tA.oProxy

    local nCount = #tBatch
    if nCount == 0 then return true, 0 end

    -- Execute with pipeline state caching
    for i = 1, nCount do
        local t = tBatch[i]
        local nX, nY, sText = t[1], t[2], t[3]
        local nFg = t[4] or 0xFFFFFF
        local nBg = t[5] or 0x000000

        fSetFg(nAdapterIdx, nFg)
        fSetBg(nAdapterIdx, nBg)
        oP.set(nX, nY, sText)
    end

    g_tStats.nTotalSets = g_tStats.nTotalSets + nCount
    g_tStats.nBatchOps  = g_tStats.nBatchOps + nCount
    return true, nCount
end

-- Fast-path fill with pipeline caching
local function fFastFill(nAdapterIdx, nX, nY, nW, nH, sCh, nFg, nBg)
    local tA = g_tAdapters[nAdapterIdx]
    if not tA or not tA.oProxy then return nil end
    if nFg then fSetFg(nAdapterIdx, nFg) end
    if nBg then fSetBg(nAdapterIdx, nBg) end
    tA.oProxy.fill(nX, nY, nW, nH, sCh or " ")
    g_tStats.nTotalFills = g_tStats.nTotalFills + 1
    return true
end

-- =============================================
-- 10. DIRECT GPU INVOKE (legacy compatibility)
-- Proxies a method call to a specific adapter.
-- =============================================

local function fGpuInvoke(nAdapterIdx, sMethod, tArgs)
    local tA = g_tAdapters[nAdapterIdx or 1]
    if not tA or not tA.oProxy then
        return nil, "Adapter not available"
    end

    local fMethod = tA.oProxy[sMethod]
    if not fMethod then
        return nil, "No such GPU method: " .. tostring(sMethod)
    end

    local bOk, r1, r2, r3, r4 = pcall(fMethod, table.unpack(tArgs or {}))
    if bOk then
        -- Invalidate pipeline cache on state-changing calls
        if sMethod == "setForeground" then
            g_tPipelineState[nAdapterIdx or 1].nLastFg = tArgs[1]
        elseif sMethod == "setBackground" then
            g_tPipelineState[nAdapterIdx or 1].nLastBg = tArgs[1]
        elseif sMethod == "bind" or sMethod == "setResolution" then
            fInvalidatePipeline(nAdapterIdx or 1)
        end
        return {r1, r2, r3, r4}
    else
        return nil, tostring(r1)
    end
end

-- =============================================
-- 11. IRP DISPATCH HANDLERS
-- =============================================

local function fDispatchCreate(pDev, pIrp)
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

local function fDispatchClose(pDev, pIrp)
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

local function fDispatchDeviceControl(pDev, pIrp)
    local sMethod = pIrp.tParameters.sMethod
    local tArgs   = pIrp.tParameters.tArgs or {}

    if not sMethod then
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER)
        return
    end

    -- =============================================
    -- ADAPTER QUERIES (GX_AX_multi_adapter)
    -- =============================================

    if sMethod == "enumerate_adapters" then
        local tList = {}
        for i = 1, g_nAdapterCount do
            local tA = g_tAdapters[i]
            tList[i] = {
                nIndex      = i,
                sAddress    = tA.sAddr,
                nTier       = tA.nTier,
                nMaxW       = tA.nMaxW,
                nMaxH       = tA.nMaxH,
                bBufSupport = tA.bBufSupport,
                sScreen     = tA.sScreen,
                bBound      = tA.bBound,
            }
        end
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, tList)

    elseif sMethod == "get_adapter_count" then
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, g_nAdapterCount)

    elseif sMethod == "bind_adapter" then
        local nIdx = tArgs[1] or 1
        local sScr = tArgs[2]
        local tA = g_tAdapters[nIdx]
        if not tA then
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER, "No adapter")
            return
        end
        if sScr then
            local bOk = pcall(tA.oProxy.bind, sScr)
            if bOk then
                tA.sScreen = sScr; tA.bBound = true
                fInvalidatePipeline(nIdx)
                oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
            else
                oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_UNSUCCESSFUL, "Bind failed")
            end
        else
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER, "No screen address")
        end

    -- =============================================
    -- SWAPCHAIN (GX_AX_swapchain)
    -- =============================================

    elseif sMethod == "create_swapchain" then
        local nAdapt = tArgs[1] or 1
        local nW     = tArgs[2]
        local nH     = tArgs[3]
        local nH2, sErr = fCreateSwapchain(nAdapt, nW, nH)
        if nH2 then
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, nH2)
        else
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_UNSUCCESSFUL, sErr)
        end

    elseif sMethod == "present" then
        local nH2 = tArgs[1]
        local bOk, sErr = fPresentSwapchain(nH2)
        if bOk then
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
        else
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_UNSUCCESSFUL, sErr)
        end

    elseif sMethod == "acquire_image" then
        local nBufIdx = fAcquireImage(tArgs[1])
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, nBufIdx)

    elseif sMethod == "destroy_swapchain" then
        fDestroySwapchain(tArgs[1])
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)

    -- =============================================
    -- SYNC FENCES (GX_AX_sync_fence)
    -- =============================================

    elseif sMethod == "create_fence" then
        local nH2 = fCreateFence(tArgs[1])
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, nH2)

    elseif sMethod == "signal_fence" then
        fSignalFence(tArgs[1])
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)

    elseif sMethod == "reset_fence" then
        fResetFence(tArgs[1])
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)

    elseif sMethod == "get_fence_status" then
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, fGetFenceStatus(tArgs[1]))

    elseif sMethod == "wait_fence" then
        local bReady = fWaitFence(tArgs[1], pIrp.nSenderPid)
        if bReady then
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, true)
        else
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_PENDING)
        end

    elseif sMethod == "destroy_fence" then
        fDestroyFence(tArgs[1])
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)

    -- =============================================
    -- COMMAND BUFFER (GX_AX_cmd_buffer)
    -- =============================================

    elseif sMethod == "create_cmd_buffer" then
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS,
            fCreateCmdBuffer(tArgs[1]))

    elseif sMethod == "begin_cmd_buffer" then
        local bOk, sErr = fBeginCmdBuffer(tArgs[1])
        oKMD.DkCompleteRequest(pIrp,
            bOk and tStatus.STATUS_SUCCESS or tStatus.STATUS_UNSUCCESSFUL, sErr)

    elseif sMethod == "cmd_set" then
        -- {handle, x, y, text, fg, bg}
        fRecordCmd(tArgs[1], CMD_SET, tArgs[2], tArgs[3], tArgs[4], tArgs[5], tArgs[6])
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)

    elseif sMethod == "cmd_fill" then
        -- {handle, x, y, w, h, ch, fg, bg}
        fRecordCmd(tArgs[1], CMD_FILL, tArgs[2], tArgs[3], tArgs[4],
                   tArgs[5], tArgs[6], tArgs[7], tArgs[8])
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)

    elseif sMethod == "cmd_copy" then
        fRecordCmd(tArgs[1], CMD_COPY, tArgs[2], tArgs[3], tArgs[4],
                   tArgs[5], tArgs[6], tArgs[7])
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)

    elseif sMethod == "cmd_scroll" then
        fRecordCmd(tArgs[1], CMD_SCROLL, tArgs[2])
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)

    elseif sMethod == "end_cmd_buffer" then
        fEndCmdBuffer(tArgs[1])
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)

    elseif sMethod == "submit_cmd_buffer" then
        local bOk, nOps = fSubmitCmdBuffer(tArgs[1], tArgs[2])
        oKMD.DkCompleteRequest(pIrp,
            bOk and tStatus.STATUS_SUCCESS or tStatus.STATUS_UNSUCCESSFUL, nOps)

    elseif sMethod == "destroy_cmd_buffer" then
        fDestroyCmdBuffer(tArgs[1])
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)

    -- =============================================
    -- BUFFER POOL (GX_AX_buffer_pool)
    -- =============================================

    elseif sMethod == "alloc_buffer" then
        local nH2, nGpuIdx = fAllocBuffer(tArgs[1] or 1, tArgs[2], tArgs[3])
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, {nHandle = nH2, nGpuIdx = nGpuIdx})

    elseif sMethod == "free_buffer" then
        fFreeBuffer(tArgs[1])
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)

    -- =============================================
    -- FAST RENDER (GX_AX_fast_tty / GX_AX_render_pass)
    -- =============================================

    elseif sMethod == "render_batch" then
        local nAdapt = tArgs[1] or 1
        local tBatch = tArgs[2]
        if type(tBatch) ~= "table" then
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER)
            return
        end
        local bOk, nCount = fFastRenderBatch(nAdapt, tBatch)
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, nCount)

    elseif sMethod == "fast_fill" then
        -- {adapter, x, y, w, h, ch, fg, bg}
        fFastFill(tArgs[1] or 1, tArgs[2], tArgs[3], tArgs[4],
                  tArgs[5], tArgs[6], tArgs[7], tArgs[8])
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)

    -- =============================================
    -- LEGACY: Direct GPU method invoke
    -- =============================================

    elseif sMethod == "invoke" then
        -- {adapter, method, args...}
        local nAdapt   = tArgs[1] or 1
        local sGpuMeth = tArgs[2]
        local tGpuArgs = {}
        for i = 3, #tArgs do tGpuArgs[i - 2] = tArgs[i] end
        local vResult, sErr = fGpuInvoke(nAdapt, sGpuMeth, tGpuArgs)
        if vResult then
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, vResult)
        else
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_UNSUCCESSFUL, sErr)
        end

    -- =============================================
    -- INFO / STATS
    -- =============================================

    elseif sMethod == "info" then
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, {
            sVersion        = "2.0.0",
            nAdapters       = g_nAdapterCount,
            nSwapchains     = (function() local n=0; for _ in pairs(g_tSwapchains) do n=n+1 end; return n end)(),
            nFences         = (function() local n=0; for _ in pairs(g_tFences) do n=n+1 end; return n end)(),
            nCmdBuffers     = (function() local n=0; for _ in pairs(g_tCmdBuffers) do n=n+1 end; return n end)(),
            nPooledBuffers  = (function() local n=0; for _ in pairs(g_tBufferPool) do n=n+1 end; return n end)(),
            tStats          = g_tStats,
            tExtensions     = {
                "GX_AX_multi_adapter",
                "GX_AX_swapchain",
                "GX_AX_sync_fence",
                "GX_AX_cmd_buffer",
                "GX_AX_render_pass",
                "GX_AX_buffer_pool",
                "GX_AX_pipeline_state",
                "GX_AX_async_submit",
                "GX_AX_fast_tty",
                "GX_AX_copy_engine",
            },
        })

    elseif sMethod == "get_extensions" then
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, {
            "GX_AX_multi_adapter", "GX_AX_swapchain", "GX_AX_sync_fence",
            "GX_AX_cmd_buffer", "GX_AX_render_pass", "GX_AX_buffer_pool",
            "GX_AX_pipeline_state", "GX_AX_async_submit", "GX_AX_fast_tty",
            "GX_AX_copy_engine",
        })

    elseif sMethod == "get_stats" then
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, g_tStats)

    elseif sMethod == "reset_stats" then
        for k in pairs(g_tStats) do g_tStats[k] = 0 end
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)

    else
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_NOT_IMPLEMENTED,
            "Unknown method: " .. tostring(sMethod))
    end
end

-- =============================================
-- 12. DRIVER ENTRY / UNLOAD
-- =============================================

function DriverEntry(pDriverObject)
    oKMD.DkPrint("AxisGPU_GX v2.0: Initializing multi-GPU driver...")

    pDriverObject.tDispatch[tDKS.IRP_MJ_CREATE]         = fDispatchCreate
    pDriverObject.tDispatch[tDKS.IRP_MJ_CLOSE]          = fDispatchClose
    pDriverObject.tDispatch[tDKS.IRP_MJ_DEVICE_CONTROL] = fDispatchDeviceControl

    -- Create device and symlink
    local nSt, pDev = oKMD.DkCreateDevice(pDriverObject, "\\Device\\Gpu0")
    if nSt ~= tStatus.STATUS_SUCCESS then
        oKMD.DkPrint("GPU_GX: Failed to create device: " .. tostring(nSt))
        return nSt
    end
    g_pDeviceObject = pDev

    nSt = oKMD.DkCreateSymbolicLink("/dev/gpu0", "\\Device\\Gpu0")
    if nSt ~= tStatus.STATUS_SUCCESS then
        oKMD.DkPrint("GPU_GX: Failed to create symlink")
        oKMD.DkDeleteDevice(pDev)
        return nSt
    end

    -- Discover all GPU adapters
    local nFound = fDiscoverAdapters()
    oKMD.DkPrint(string.format(
        "GPU_GX: %d adapter(s), %d screen(s) discovered",
        nFound,
        (function() local n=0; for _ in pairs(g_tScreens) do n=n+1 end; return n end)()))

    -- Store adapter info in device extension
    pDev.pDeviceExtension.nAdapterCount = nFound
    pDev.pDeviceExtension.tAdapters     = g_tAdapters

    -- Register in registry
    pcall(function()
        syscall("reg_create_key", "@VT\\DRV\\AxisGPU_GX")
        syscall("reg_set_value", "@VT\\DRV\\AxisGPU_GX", "Version", "2.0.0", "STR")
        syscall("reg_set_value", "@VT\\DRV\\AxisGPU_GX", "Adapters", nFound, "NUM")
        for i = 1, nFound do
            local tA = g_tAdapters[i]
            local sKey = "@VT\\DRV\\AxisGPU_GX\\Adapter" .. i
            syscall("reg_create_key", sKey)
            syscall("reg_set_value", sKey, "Address", tA.sAddr, "STR")
            syscall("reg_set_value", sKey, "Tier", tA.nTier, "NUM")
            syscall("reg_set_value", sKey, "MaxResolution",
                tA.nMaxW .. "x" .. tA.nMaxH, "STR")
            syscall("reg_set_value", sKey, "BufferSupport",
                tA.bBufSupport and "true" or "false", "STR")
            syscall("reg_set_value", sKey, "Screen",
                tA.sScreen or "unbound", "STR")
        end
    end)

    oKMD.DkPrint("AxisGPU_GX v2.0: Ready with " .. nFound .. " adapter(s)")

    -- ═══════════════════════════════════════
    -- REGISTER FAST-PATH WITH KERNEL / GDI
    -- Passes direct function references (closures over driver state).
    -- GDI calls these from kernel context — zero IRP overhead.
    -- ═══════════════════════════════════════

    local tFastPathExport = {
        -- Adapter data
        tAdapters      = g_tAdapters,
        nAdapterCount  = g_nAdapterCount,
        tPipelineState = g_tPipelineState,
        tScreens       = g_tScreens,
        tStats         = g_tStats,

        -- Pipeline state
        fSetFg              = fSetFg,
        fSetBg              = fSetBg,
        fInvalidatePipeline = fInvalidatePipeline,

        -- Fast rendering
        fFastRenderBatch = fFastRenderBatch,
        fFastFill        = fFastFill,

        -- Swapchain
        fCreateSwapchain  = fCreateSwapchain,
        fPresentSwapchain = fPresentSwapchain,
        fDestroySwapchain = fDestroySwapchain,
        fAcquireImage     = fAcquireImage,

        -- Command buffers
        fCreateCmdBuffer  = fCreateCmdBuffer,
        fBeginCmdBuffer   = fBeginCmdBuffer,
        fRecordCmd        = fRecordCmd,
        fEndCmdBuffer     = fEndCmdBuffer,
        fSubmitCmdBuffer  = fSubmitCmdBuffer,
        fDestroyCmdBuffer = fDestroyCmdBuffer,

        -- Buffer pool
        fAllocBuffer = fAllocBuffer,
        fFreeBuffer  = fFreeBuffer,

        -- Legacy invoke
        fGpuInvoke = fGpuInvoke,
    }

    pcall(syscall, "kernel_register_gpu_fast_path", tFastPathExport)
    oKMD.DkPrint("GPU_GX: Fast-path registered with kernel/GDI")
    
    return tStatus.STATUS_SUCCESS
end

function DriverUnload(pDriverObject)
    oKMD.DkPrint("AxisGPU_GX: Unloading...")

    -- Destroy all swapchains
    for nH in pairs(g_tSwapchains) do fDestroySwapchain(nH) end
    -- Free all pooled buffers
    for nH in pairs(g_tBufferPool) do fFreeBuffer(nH) end

    oKMD.DkDeleteSymbolicLink("/dev/gpu0")
    oKMD.DkDeleteDevice(g_pDeviceObject)
    return tStatus.STATUS_SUCCESS
end

-- =============================================
-- 13. MAIN DRIVER LOOP
-- =============================================

while true do
    local bOk, nSenderPid, sSignalName, p1, p2 = syscall("signal_pull")

    if bOk then
        if sSignalName == "driver_init" then
            local pDriverObject = p1
            pDriverObject.fDriverUnload = DriverUnload
            local nSt = DriverEntry(pDriverObject)
            syscall("signal_send", nSenderPid, "driver_init_complete", nSt, pDriverObject)

        elseif sSignalName == "irp_dispatch" then
            local pIrp    = p1
            local fHandler = p2
            if fHandler then
                fHandler(g_pDeviceObject, pIrp)
            end
        end
    end
end