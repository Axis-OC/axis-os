-- /system/gdi.lua
-- Graphics Device Interface — kernel module
-- Loaded at boot like PatchGuard. Manages GPUs, surfaces, compositing.

local GDI = {}

-- ═══════════════════════════════════════════
-- STATE
-- ═══════════════════════════════════════════

local g_tGpus           = {}   -- [idx] = {proxy, address, screenAddr, nW, nH, …}
local g_tScreens        = {}   -- [addr] = {address, gpuIdx}
local g_tSurfaces       = {}   -- [handle] = surface
local g_nNextHandle     = 1
local g_nFocusedSurface = nil
local g_tInputQueues    = {}   -- [handle] = {events…}
local g_tScreenBuf      = {}   -- [gpuIdx][y] = {sChars, tFg, tBg}
local g_fLog            = function() end
local g_nMaxZSeen       = 0

local GPU_BUDGET_PER_TICK = 6  -- conservative; leave headroom

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

    g_fLog(string.format("[GDI] %d GPU(s), %d screen(s)", nIdx, nScr))
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

    -- Build screen buffer (what's physically displayed)
    g_tScreenBuf[nIdx] = {}
    for y = 1, tGpu.nH do
        g_tScreenBuf[nIdx][y] = _newRow(tGpu.nW)
        g_tScreenBuf[nIdx][y].bDirty = false
    end

    -- Clear physical screen
    tGpu.proxy.setBackground(0x000000)
    tGpu.proxy.setForeground(0xFFFFFF)
    tGpu.proxy.fill(1, 1, tGpu.nW, tGpu.nH, " ")

    if g_tScreens[sScreenAddr] then
        g_tScreens[sScreenAddr].gpuIdx = nIdx
    end

    g_fLog(string.format("[GDI] GPU %d → %s (%dx%d)",
        nIdx, sScreenAddr:sub(1, 8), tGpu.nW, tGpu.nH))
    return true
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

    -- Preserve existing content where possible
    local tNewRows = {}
    for y = 1, nNewH do
        if y <= s.nH then
            local old = s.tRows[y]
            local r = _newRow(nNewW)
            local nCopy = math.min(s.nW, nNewW)
            r.sChars = old.sChars:sub(1, nCopy) ..
                       string.rep(" ", math.max(0, nNewW - nCopy))
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
        -- Mark all rows dirty so compositor picks up the change
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
-- COMPOSITOR
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

        local nLastFg, nLastBg

        for _, s in ipairs(tVis) do
            for sy = 1, s.nH do
                local r = s.tRows[sy]
                if not r.bDirty then goto nextSRow end

                local nPhysY = s.nScreenY + sy - 1
                if nPhysY < 1 or nPhysY > tGpu.nH then goto nextSRow end
                local tScr = tSBuf[nPhysY]

                -- Walk the row finding color runs, diff against screen
                local x = 1
                while x <= s.nW do
                    local nPhysX = s.nScreenX + x - 1
                    if nPhysX > tGpu.nW then break end

                    local nFg = r.tFg[x]
                    local nBg = r.tBg[x]

                    -- Extend run of identical fg+bg
                    local xEnd = x
                    while xEnd < s.nW do
                        local nx = xEnd + 1
                        if r.tFg[nx] ~= nFg or r.tBg[nx] ~= nBg then break end
                        if s.nScreenX + nx - 1 > tGpu.nW then break end
                        xEnd = nx
                    end

                    local nRunLen = xEnd - x + 1
                    local nPX     = s.nScreenX + x - 1
                    local sNew    = r.sChars:sub(x, xEnd)

                    -- Diff against screen buffer
                    local sOld     = tScr.sChars:sub(nPX, nPX + nRunLen - 1)
                    local bChanged = (sNew ~= sOld)

                    if not bChanged then
                        for cx = 0, nRunLen - 1 do
                            if tScr.tFg[nPX + cx] ~= r.tFg[x + cx] or
                               tScr.tBg[nPX + cx] ~= r.tBg[x + cx] then
                                bChanged = true; break
                            end
                        end
                    end

                    if bChanged then
                        -- Budget check
                        local nCost = 1  -- gpu.set
                        if nFg ~= nLastFg then nCost = nCost + 1 end
                        if nBg ~= nLastBg then nCost = nCost + 1 end
                        if nTotalCalls + nCost > GPU_BUDGET_PER_TICK then
                            -- Over budget — stop, finish next tick
                            -- DON'T clear dirty flags for unrendered rows
                            return nTotalCalls
                        end

                        if nFg ~= nLastFg then
                            oGpu.setForeground(nFg)
                            nLastFg = nFg
                            nTotalCalls = nTotalCalls + 1
                        end
                        if nBg ~= nLastBg then
                            oGpu.setBackground(nBg)
                            nLastBg = nBg
                            nTotalCalls = nTotalCalls + 1
                        end
                        oGpu.set(nPX, nPhysY, sNew)
                        nTotalCalls = nTotalCalls + 1

                        -- Update screen buffer
                        tScr.sChars = tScr.sChars:sub(1, nPX - 1)
                                    .. sNew
                                    .. tScr.sChars:sub(nPX + nRunLen)
                        for cx = 0, nRunLen - 1 do
                            tScr.tFg[nPX + cx] = r.tFg[x + cx]
                            tScr.tBg[nPX + cx] = r.tBg[x + cx]
                        end
                    end

                    x = xEnd + 1
                end

                r.bDirty = false
                ::nextSRow::
            end
        end

        ::nextGpu::
    end
    return nTotalCalls
end

-- Force every row dirty (e.g. after GPU rebind)
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
        sType   = sType,    -- "key_down" / "key_up"
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