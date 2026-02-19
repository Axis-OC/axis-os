--
-- /lib/xe.lua
-- XE Graphics v2 — High-Performance TUI Rendering Engine for AxisOS
--
-- Extension-based architecture. Each extension is nearly independent.
-- Enable only what your application needs.
--
-- EXTENSIONS:
--
--   XE_ui_shadow_buffering_render_batch
--       Maintains a per-cell shadow buffer (front + delta).
--       text() writes to a delta layer; endFrame() compiles delta into
--       one render_batch device control call. Enables per-cell diffing.
--
--   XE_ui_shadow_buffering_generic_render
--       Same shadow buffer, but flushes per-row instead of one big batch.
--       Lower peak memory, higher IPC overhead. Mutually exclusive with
--       render_batch variant; if both are set, render_batch wins.
--
--   XE_ui_diff_render_feature
--       Compares delta cells against the front buffer and emits only
--       cells that actually changed. Requires one of the shadow buffer
--       extensions (auto-enables render_batch if neither is set).
--
--   XE_ui_alt_screen_query
--       Enters the TTY alternate screen on context creation and leaves
--       it on destroy. Preserves the shell's screen underneath.
--
--   XE_ui_alt_screen_query_batch
--       Extends XE_ui_alt_screen_query: clears the alt screen via a
--       single gpu_fill on enter. Auto-enables alt_screen_query.
--
--   XE_ui_deferred_clear
--       ctx:clear(bg) stores the color; actual gpu_fill is deferred to
--       endFrame(), avoiding per-cell delta writes for full clears.
--
--   XE_ui_imgui_navigation
--       IMGUI keyboard-driven widget system: Tab/arrows cycle focus,
--       Enter activates. Provides button(), selectable(), label().
--
--   XE_ui_dirty_row_tracking
--       Only rows touched by text()/fill() are processed at flush time.
--       Combined with diff, untouched rows are skipped entirely.
--       Auto-enables a shadow buffer extension if neither is set.
--
--   XE_ui_run_length_grouping
--       When building batch entries, consecutive same-color delta cells
--       are merged into one entry. Reduces render_batch entry count and
--       GPU set() calls.
--
-- CELL STORAGE:
--   Front buffer stores characters as individual single-char strings in
--   tables:  _fCh[y][x] = "A",  _fFg[y][x] = 0xFFFFFF, etc.
--   Characters are compiled into strings via table.concat() only when
--   building render_batch output.
--
-- FAST PATH (no extensions):
--   ctx:text() adds directly to the batch table.
--   ctx:endFrame() flushes via one render_batch call.
--   Zero per-cell overhead, but redraws everything every frame.
--
-- OPTIMAL PATH (all render extensions):
--   ctx:text() writes to sparse per-cell delta tables.
--   ctx:endFrame() diffs dirty rows against front buffer,
--   groups same-color runs, emits minimal batch entries.
--   If nothing changed, endFrame() is a no-op.
--
-- Usage:
--   local xe = require("xe")
--   local ctx = xe.createContext({
--       extensions = {
--           "XE_ui_shadow_buffering_render_batch",
--           "XE_ui_diff_render_feature",
--           "XE_ui_alt_screen_query",
--           "XE_ui_deferred_clear",
--           "XE_ui_imgui_navigation",
--           "XE_ui_dirty_row_tracking",
--           "XE_ui_run_length_grouping",
--       }
--   })
--   while running do
--       ctx:beginFrame()
--       ctx:clear(0x0C0C1E)
--       ctx:text(2, 2, "Hello", 0x55FFFF)
--       if ctx:button("q", 2, 4, " Quit ") then break end
--       ctx:endFrame()
--   end
--   ctx:destroy()
--

local fs = require("filesystem")

local XE = {}
XE.FG = 0xFFFFFF
XE.BG = 0x000000

-- Capture syscall for voluntary yields (process_yield doesn't
-- pollute the preemption counter like raw coroutine.yield does)
local _fSysYield
do
    local ok, fn = pcall(function() return syscall end)
    if ok and type(fn) == "function" then
        _fSysYield = function() fn("process_yield") end
    else
        _fSysYield = function() coroutine.yield() end
    end
end

local _BCHAR = {}
for i = 0, 255 do _BCHAR[i] = string.char(i) end
local _SPACE_BYTE = 32

-- Gap-bridging: max unchanged cells to absorb into a color run
local _GAP_MAX = 3

-- Fill area above this threshold uses a single gpu_fill IPC call
-- instead of per-cell delta writes
local _FILL_GPU_THRESHOLD = 48
local _NOCLEAR = false

-- =============================================
-- BUILT-IN THEMES
-- =============================================

XE.THEMES = {
    dark = {
        bg       = 0x0C0C1E, fg       = 0xCCCCDD,
        accent   = 0x55FFFF, accent2  = 0x55FF55,
        border   = 0x3A3A5E, title    = 0x55FFFF,
        sel_fg   = 0x000000, sel_bg   = 0xFFFF00,
        btn_fg   = 0xFFFFFF, btn_bg   = 0x333366,
        btn_hfg  = 0x000000, btn_hbg  = 0xFFFF00,
        err      = 0xFF5555, ok       = 0x55FF55,
        warn     = 0xFFFF55, dim      = 0x555555,
        bar_fg   = 0xFFFFFF, bar_bg   = 0x0D2B52,
        input_fg = 0xFFFFFF, input_bg = 0x111133,
        input_afg= 0xFFFFFF, input_abg= 0x222255,
        scroll_thumb = 0xAAAAAA, scroll_track = 0x333333,
        scroll_bg    = 0x111111,
    },
    light = {
        bg       = 0xE8E8E8, fg       = 0x222222,
        accent   = 0x0066CC, accent2  = 0x008800,
        border   = 0xAAAAAA, title    = 0x0066CC,
        sel_fg   = 0xFFFFFF, sel_bg   = 0x0066CC,
        btn_fg   = 0xFFFFFF, btn_bg   = 0x666666,
        btn_hfg  = 0xFFFFFF, btn_hbg  = 0x0066CC,
        err      = 0xCC0000, ok       = 0x008800,
        warn     = 0xCC8800, dim      = 0x999999,
        bar_fg   = 0xFFFFFF, bar_bg   = 0x444444,
        input_fg = 0x000000, input_bg = 0xFFFFFF,
        input_afg= 0x000000, input_abg= 0xDDDDFF,
        scroll_thumb = 0x666666, scroll_track = 0xCCCCCC,
        scroll_bg    = 0xDDDDDD,
    },
}

-- =============================================
-- 1. EXTENSION REGISTRY
-- =============================================

local ALL_EXT = {
    "XE_ui_shadow_buffering_render_batch",
    "XE_ui_shadow_buffering_generic_render",
    "XE_ui_diff_render_feature",
    "XE_ui_alt_screen_query",
    "XE_ui_alt_screen_query_batch",
    "XE_ui_deferred_clear",
    "XE_ui_imgui_navigation",
    "XE_ui_dirty_row_tracking",
    "XE_ui_run_length_grouping",
    "XE_ui_suspend_resume",
    "XE_ui_page_manager",
    "XE_ui_gpu_double_buffer",
    "XE_ui_gpu_page_snapshot",
}

function XE.enumerateExtensions()
    local t = {}
    for i = 1, #ALL_EXT do t[i] = ALL_EXT[i] end
    return t
end

function XE.queryExtension(s)
    for i = 1, #ALL_EXT do
        if ALL_EXT[i] == s then return true end
    end
    return false
end

-- =============================================
-- 2. CONTEXT CREATION
-- =============================================

function XE.createContext(cfg)
    cfg = cfg or {}

    local ext = {}
    if cfg.extensions then
        for i = 1, #cfg.extensions do ext[cfg.extensions[i]] = true end
    end

    -- ===== Existing dependency resolution =====
    if ext.XE_ui_diff_render_feature then
        if not ext.XE_ui_shadow_buffering_render_batch
           and not ext.XE_ui_shadow_buffering_generic_render then
            ext.XE_ui_shadow_buffering_render_batch = true
        end
    end
    if ext.XE_ui_dirty_row_tracking then
        if not ext.XE_ui_shadow_buffering_render_batch
           and not ext.XE_ui_shadow_buffering_generic_render then
            ext.XE_ui_shadow_buffering_render_batch = true
        end
    end
    if ext.XE_ui_alt_screen_query_batch then
        ext.XE_ui_alt_screen_query = true
    end
    if ext.XE_ui_shadow_buffering_render_batch
       and ext.XE_ui_shadow_buffering_generic_render then
        ext.XE_ui_shadow_buffering_generic_render = nil
    end
    if ext.XE_ui_run_length_grouping then
        if not ext.XE_ui_shadow_buffering_render_batch
           and not ext.XE_ui_shadow_buffering_generic_render then
            ext.XE_ui_shadow_buffering_render_batch = true
        end
    end
    if ext.XE_ui_shadow_buffering_render_batch
       or ext.XE_ui_shadow_buffering_generic_render then
        if not ext.XE_ui_diff_render_feature then
            ext.XE_ui_diff_render_feature = true
        end
    end

    -- ===== NEW dependency resolution =====
    if ext.XE_ui_page_manager then
        ext.XE_ui_suspend_resume = true
    end
    if ext.XE_ui_gpu_page_snapshot then
        ext.XE_ui_gpu_double_buffer = true
        ext.XE_ui_suspend_resume = true
    end

    local hIn  = fs.open("/dev/tty", "r")
    local hOut = fs.open("/dev/tty", "w")
    if not hIn or not hOut then return nil, "no tty" end

    fs.deviceControl(hIn, "set_mode", {"raw"})
    -- Enable non-blocking reads for live-updating apps
    fs.deviceControl(hIn, "set_nonblock", {true})
    local bSz, tSz = fs.deviceControl(hIn, "get_size", {})
    local W = (bSz and tSz and tSz.w) or (cfg.width  or 80)
    local H = (bSz and tSz and tSz.h) or (cfg.height or 25)

    if ext.XE_ui_alt_screen_query then
        fs.deviceControl(hIn, "enter_alt_screen", {})
    end

    local bShadow = (ext.XE_ui_shadow_buffering_render_batch
                  or ext.XE_ui_shadow_buffering_generic_render) and true or false
    local bDiff   = ext.XE_ui_diff_render_feature and true or false
    local bBatch  = ext.XE_ui_shadow_buffering_render_batch and true or false
    local bGenR   = ext.XE_ui_shadow_buffering_generic_render and true or false
    local bImgui  = ext.XE_ui_imgui_navigation and true or false
    local bDirty  = ext.XE_ui_dirty_row_tracking and true or false
    local bRunGrp = ext.XE_ui_run_length_grouping and true or false

    local tSpaceCache = {}
    for w = 1, W do tSpaceCache[w] = string.rep(" ", w) end

    local ctx = {
        W = W, H = H,
        _hIn = hIn, _hOut = hOut,
        _ext = ext, _alive = true,

        _bShadow = bShadow, _bDiff = bDiff, _bBatch = bBatch,
        _bGenR = bGenR, _bImgui = bImgui,
        _bDirty = bDirty, _bRunGrp = bRunGrp,

        _baseFg = XE.FG, _baseBg = XE.BG,

        _bat = {}, _nB = 0,
        _runBuf = {},
        _spCache = tSpaceCache,

        _clearBg     = _NOCLEAR,
        _prevClearBg = _NOCLEAR,

        -- IMGUI
        _wIds = {}, _nW = 0,
        _focIdx = 0, _focId = nil,
        _key = nil, _act = false, _first = true,

        _theme = cfg.theme or (XE.THEMES and XE.THEMES.dark) or nil,

        _clipStack = {}, _nClip = 0,
        _scrollState = {},
        _activeScroll = nil,
        _inputState = {},

        -- Front buffer
        _fCh = {}, _fFg = {}, _fBg = {},
        -- Delta buffer
        _dCh = {}, _dFg = {}, _dBg = {},
        -- Dirty rows
        _dtyR = {}, _nDty = 0,
        _prevDtyR = {},

        -- ===== NEW: Suspend/Resume =====
        _suspended = false,

        -- ===== NEW: Page Manager =====
        _pages = {},
        _activePage = nil,

        -- ===== NEW: GPU Double Buffer =====
        _gpuBufId = nil,     -- off-screen buffer index (nil = not available)
        _bGpuBuf = false,    -- GPU buffers supported?

        -- ===== NEW: GPU Page Snapshots =====
        _gpuPageBufs = {},   -- pageId → GPU buffer index
    }

    -- Allocate front buffer if shadow enabled
    if bShadow then
        local fCh, fFg, fBg = ctx._fCh, ctx._fFg, ctx._fBg
        for y = 1, H do
            local rCh, rFg, rBg = {}, {}, {}
            for x = 1, W do
                rCh[x] = _SPACE_BYTE
                rFg[x] = XE.FG
                rBg[x] = XE.BG
            end
            fCh[y] = rCh; fFg[y] = rFg; fBg[y] = rBg
        end
    end

    -- ===== NEW: Probe GPU buffer support =====
    if ext.XE_ui_gpu_double_buffer then
        local bProbe, vResult = fs.deviceControl(hIn, "gpu_has_buffers", {})
        ctx._bGpuBuf = (bProbe and vResult == true)
        if ctx._bGpuBuf then
            -- Allocate off-screen render buffer
            local bAlloc, nBufIdx = fs.deviceControl(hIn, "gpu_alloc_buffer", {W, H})
            if bAlloc and nBufIdx and nBufIdx > 0 then
                ctx._gpuBufId = nBufIdx
            else
                ctx._bGpuBuf = false  -- alloc failed, fallback
            end
        end
    end

    return setmetatable(ctx, { __index = XE._M })
end

-- Method table
XE._M = {}

-- Allocate fresh front buffer (all spaces, default colors).
-- O(W*H) but unavoidable.  Delta/dirty tables start empty (free).
function XE._M:_allocFrontBuffer()
    local W, H = self.W, self.H
    local fCh, fFg, fBg = {}, {}, {}
    for y = 1, H do
        local rCh, rFg, rBg = {}, {}, {}
        for x = 1, W do
            rCh[x] = _SPACE_BYTE
            rFg[x] = XE.FG
            rBg[x] = XE.BG
        end
        fCh[y] = rCh; fFg[y] = rFg; fBg[y] = rBg
    end
    self._fCh = fCh; self._fFg = fFg; self._fBg = fBg
    self._dCh = {}; self._dFg = {}; self._dBg = {}
    self._dtyR = {}; self._nDty = 0; self._prevDtyR = {}
    -- Batch/run buffers are shared scratch — just reset counts
    if not self._bat then self._bat = {} end
    self._nB = 0
    if not self._runBuf then self._runBuf = {} end
    if not self._spCache then
        local t = {}
        for w = 1, self.W do t[w] = string.rep(" ", w) end
        self._spCache = t
    end
    self._clearBg = _NOCLEAR
    self._prevClearBg = _NOCLEAR
end


-- =============================================
-- 3. LIFECYCLE
-- =============================================

function XE._M:destroy()
    if not self._alive then return end
    self._alive = false
    -- Restore blocking reads for subsequent apps (shell, vi, etc.)
    fs.deviceControl(self._hIn, "set_nonblock", {false})
    if self._gpuBufId and self._bGpuBuf then
        fs.deviceControl(self._hIn, "gpu_free_buffer", {self._gpuBufId})
        self._gpuBufId = nil
    end
    for sId, pg in pairs(self._pages) do
        if pg.gpuBuf and self._bGpuBuf then
            fs.deviceControl(self._hIn, "gpu_free_buffer", {pg.gpuBuf})
        end
    end
    self._pages = {}
    if self._ext.XE_ui_alt_screen_query then
        fs.deviceControl(self._hIn, "leave_alt_screen", {})
    end
    fs.deviceControl(self._hIn, "set_mode", {"cooked"})
    fs.close(self._hIn)
    fs.close(self._hOut)
end

-- =============================================
-- 4. FRAME MANAGEMENT
-- =============================================

function XE._M:beginFrame()
    if self._suspended then return false end

    if self._first then
        self._key = nil; self._first = false
    else
        -- Non-blocking: returns nil instantly if no key buffered
        self._key = fs.read(self._hIn)
        if not self._key then
            _fSysYield()  -- ~50ms pause, prevents busy-loop
        end
    end
    self._act = false

    if self._bImgui and self._key then
        local k = self._key
        if k == "\t" then
            if self._nW > 0 then
                self._focIdx = (self._focIdx % self._nW) + 1
                self._focId  = self._wIds[self._focIdx]
            end
            self._key = nil
        elseif k == "\n" then
            self._act = true
        end
        self._nW = 0
    end

    self._prevDtyR    = self._dtyR
    self._prevClearBg = self._clearBg

    local dCh, dFg, dBg = self._dCh, self._dFg, self._dBg
    if self._prevDtyR then
        for y in pairs(self._prevDtyR) do
            dCh[y] = nil; dFg[y] = nil; dBg[y] = nil
        end
    end

    self._dtyR   = {}
    self._nDty   = 0
    self._nB     = 0
    self._clearBg = _NOCLEAR
    self._activeScroll = nil

    if self._gpuBufId then
        fs.deviceControl(self._hIn, "gpu_set_active_buffer", {self._gpuBufId})
    end

    return self._key ~= nil
end

function XE._M:endFrame()
    -- ===== SUSPEND GUARD =====
    if self._suspended then return end

    if self._bImgui and self._nW > 0 then
        local found = false
        local wIds, focId = self._wIds, self._focId
        for i = 1, self._nW do
            if wIds[i] == focId then found = true; self._focIdx = i; break end
        end
        if not found then self._focIdx = 1; self._focId = wIds[1] end
    end

    if self._bShadow then
        local hasClear = (self._clearBg ~= _NOCLEAR)
        if hasClear then
            self:_flushWithClear()
        else
            if self._nDty == 0 then
                -- ===== GPU DOUBLE BUFFER: restore screen target even on no-op =====
                if self._gpuBufId then
                    fs.deviceControl(self._hIn, "gpu_set_active_buffer", {0})
                end
                return
            end
            if self._bDiff then
                self:_flushDiff()
            else
                self:_flushShadowNoDiff()
            end
        end
    else
        if self._nB == 0 then
            if self._gpuBufId then
                fs.deviceControl(self._hIn, "gpu_set_active_buffer", {0})
            end
            return
        end
    end

    -- Emit the batch
    if self._nB > 0 then
        local bat = self._bat
        for i = self._nB + 1, #bat do bat[i] = nil end

        if self._bGenR then
            local nStart = 1
            while nStart <= self._nB do
                local curY = bat[nStart][2]
                local nEnd = nStart
                while nEnd < self._nB and bat[nEnd+1][2] == curY do nEnd = nEnd+1 end
                local tRow = {}
                for i = nStart, nEnd do tRow[#tRow+1] = bat[i] end
                fs.deviceControl(self._hIn, "render_batch", tRow)
                nStart = nEnd + 1
            end
        else
            fs.deviceControl(self._hIn, "render_batch", bat)
        end
        self._nB = 0
    end

    -- ===== GPU DOUBLE BUFFER: bitblt off-screen → screen =====
    if self._gpuBufId then
        fs.deviceControl(self._hIn, "gpu_bitblt",
            {0, 1, 1, self.W, self.H, self._gpuBufId, 1, 1})
        fs.deviceControl(self._hIn, "gpu_set_active_buffer", {0})
    end
end

-- =============================================
-- 5. INTERNAL FLUSH: SHADOW NO-DIFF
-- Walks dirty rows, compiles ALL delta cells to batch.
-- No comparison against front buffer.
-- =============================================

function XE._M:_flushShadowNoDiff()
    local W      = self.W
    local dCh, dFg, dBg = self._dCh, self._dFg, self._dBg
    local fCh, fFg, fBg = self._fCh, self._fFg, self._fBg
    local baseFg = self._baseFg
    local baseBg = self._baseBg
    local bGroup = self._bRunGrp
    local runBuf = self._runBuf
    local bat, nB = self._bat, self._nB
    local BCHAR  = _BCHAR

    -- Collect and sort dirty rows
    local tRows, nRows = {}, 0
    if self._bDirty then
        for y in pairs(self._dtyR) do nRows=nRows+1; tRows[nRows]=y end
    else
        for y in pairs(dCh) do nRows=nRows+1; tRows[nRows]=y end
    end
    for i = 2, nRows do
        local v = tRows[i]; local j = i-1
        while j >= 1 and tRows[j] > v do tRows[j+1]=tRows[j]; j=j-1 end
        tRows[j+1] = v
    end

    for ri = 1, nRows do
        local y  = tRows[ri]
        local dc = dCh[y]; if not dc then goto nextND end
        local df, db = dFg[y], dBg[y]
        local fc, ff, fb = fCh[y], fFg[y], fBg[y]

        if bGroup then
            local x = 1
            while x <= W do
                local ch = dc[x]
                if ch then
                    local cfg, cbg = df[x] or baseFg, db[x] or baseBg
                    local sx, nR = x, 1
                    runBuf[1] = BCHAR[ch]
                    fc[x]=ch; ff[x]=cfg; fb[x]=cbg
                    x = x + 1
                    while x <= W and dc[x] do
                        local nfg = df[x] or baseFg
                        local nbg = db[x] or baseBg
                        if nfg ~= cfg or nbg ~= cbg then break end
                        nR=nR+1; runBuf[nR]=BCHAR[dc[x]]
                        fc[x]=dc[x]; ff[x]=nfg; fb[x]=nbg
                        x = x + 1
                    end
                    local sRun = table.concat(runBuf, "", 1, nR)
                    nB=nB+1
                    local e = bat[nB]
                    if e then e[1]=sx;e[2]=y;e[3]=sRun;e[4]=cfg;e[5]=cbg
                    else bat[nB]={sx,y,sRun,cfg,cbg} end
                else
                    x = x + 1
                end
            end
        else
            for x = 1, W do
                local ch = dc[x]
                if ch then
                    local cfg, cbg = df[x] or baseFg, db[x] or baseBg
                    fc[x]=ch; ff[x]=cfg; fb[x]=cbg
                    nB=nB+1
                    local e = bat[nB]
                    if e then e[1]=x;e[2]=y;e[3]=BCHAR[ch];e[4]=cfg;e[5]=cbg
                    else bat[nB]={x,y,BCHAR[ch],cfg,cbg} end
                end
            end
        end
        ::nextND::
    end
    self._nB = nB
end

-- =============================================
-- 6. INTERNAL FLUSH: SHADOW + DIFF
-- Walks dirty rows, compares delta vs front buffer,
-- emits only cells that actually changed.
-- =============================================

function XE._M:_flushDiff()
    local W      = self.W
    local dCh, dFg, dBg = self._dCh, self._dFg, self._dBg
    local fCh, fFg, fBg = self._fCh, self._fFg, self._fBg
    local baseFg = self._baseFg
    local baseBg = self._baseBg
    local bGroup = self._bRunGrp
    local runBuf = self._runBuf
    local bat, nB = self._bat, self._nB
    local BCHAR  = _BCHAR

    -- Collect and sort dirty rows
    local tRows, nRows = {}, 0
    if self._bDirty then
        for y in pairs(self._dtyR) do nRows=nRows+1; tRows[nRows]=y end
    else
        for y in pairs(dCh) do nRows=nRows+1; tRows[nRows]=y end
    end
    for i = 2, nRows do
        local v = tRows[i]; local j = i-1
        while j >= 1 and tRows[j] > v do tRows[j+1]=tRows[j]; j=j-1 end
        tRows[j+1] = v
    end

    for ri = 1, nRows do
        local y  = tRows[ri]
        local dc = dCh[y]; if not dc then goto nextD end
        local df, db = dFg[y], dBg[y]
        local fc, ff, fb = fCh[y], fFg[y], fBg[y]

        if bGroup then
            -- ---- Diff + run-length grouping + gap-bridging ----
            local x = 1
            while x <= W do
                local ch = dc[x]
                if not ch then x = x + 1; goto contD end

                local cfg = df[x] or baseFg
                local cbg = db[x] or baseBg

                -- Unchanged? skip
                if ch == fc[x] and cfg == ff[x] and cbg == fb[x] then
                    x = x + 1; goto contD
                end

                -- ---- Start a changed-cell run ----
                local sx, nR = x, 1
                runBuf[1] = BCHAR[ch]
                fc[x]=ch; ff[x]=cfg; fb[x]=cbg
                x = x + 1

                -- ---- Extend the run ----
                while x <= W do
                    local nch = dc[x]
                    if nch then
                        local nfg = df[x] or baseFg
                        local nbg = db[x] or baseBg
                        if nfg ~= cfg or nbg ~= cbg then break end  -- color break
                        -- Same color: changed?
                        if nch ~= fc[x] or nfg ~= ff[x] or nbg ~= fb[x] then
                            -- Changed — extend
                            nR=nR+1; runBuf[nR]=BCHAR[nch]
                            fc[x]=nch; ff[x]=nfg; fb[x]=nbg
                            x = x + 1
                        else
                            -- Unchanged same-color cell — try gap-bridge
                            goto tryBridge
                        end
                    else
                        -- No delta at x — try gap-bridge
                        goto tryBridge
                    end
                    goto contRun

                    ::tryBridge::
                    -- Peek ahead up to _GAP_MAX positions for a
                    -- changed cell with the same color
                    local bridgeTo = nil
                    local pMax = x + _GAP_MAX
                    if pMax > W then pMax = W end
                    for px = x, pMax do
                        local pch = dc[px]
                        if pch then
                            local pfg = df[px] or baseFg
                            local pbg = db[px] or baseBg
                            if pfg ~= cfg or pbg ~= cbg then break end
                            if pch ~= fc[px] or pfg ~= ff[px] or pbg ~= fb[px] then
                                bridgeTo = px; break
                            end
                            -- Same color, unchanged — keep scanning
                        end
                        -- No delta here — gap cell, keep scanning
                    end

                    if bridgeTo then
                        -- Bridge: include gap cells using front-buffer values
                        for bx = x, bridgeTo do
                            nR = nR + 1
                            local bch = dc[bx]
                            if bch then
                                runBuf[nR] = BCHAR[bch]
                                fc[bx]=bch
                                ff[bx]=df[bx] or baseFg
                                fb[bx]=db[bx] or baseBg
                            else
                                runBuf[nR] = BCHAR[fc[bx]]  -- unchanged front value
                            end
                        end
                        x = bridgeTo + 1
                    else
                        break  -- no bridge target — end run
                    end

                    ::contRun::
                end

                -- Emit the accumulated run
                local sRun = table.concat(runBuf, "", 1, nR)
                nB=nB+1
                local e = bat[nB]
                if e then e[1]=sx;e[2]=y;e[3]=sRun;e[4]=cfg;e[5]=cbg
                else bat[nB]={sx,y,sRun,cfg,cbg} end

                ::contD::
            end
        else
            -- ---- Diff, no grouping ----
            for x = 1, W do
                local ch = dc[x]
                if ch then
                    local cfg = df[x] or baseFg
                    local cbg = db[x] or baseBg
                    if ch ~= fc[x] or cfg ~= ff[x] or cbg ~= fb[x] then
                        fc[x]=ch; ff[x]=cfg; fb[x]=cbg
                        nB=nB+1
                        local e = bat[nB]
                        if e then e[1]=x;e[2]=y;e[3]=BCHAR[ch];e[4]=cfg;e[5]=cbg
                        else bat[nB]={x,y,BCHAR[ch],cfg,cbg} end
                    end
                end
            end
        end
        ::nextD::
    end
    self._nB = nB
end

function XE._M:_flushWithClear()
    local W      = self.W
    local H      = self.H
    local clrBg  = self._clearBg
    local clrFg  = self._baseFg
    local dCh, dFg, dBg = self._dCh, self._dFg, self._dBg
    local fCh, fFg, fBg = self._fCh, self._fFg, self._fBg
    local dtyR     = self._dtyR
    local prevDtyR = self._prevDtyR
    local bRunGrp  = self._bRunGrp
    local runBuf   = self._runBuf
    local bat, nB  = self._bat, self._nB
    local BCHAR    = _BCHAR

    -- Detect bg color change (first frame, or theme switch)
    local bgChanged = (clrBg ~= self._prevClearBg)

    -- On first-time bg change: issue ONE gpu_fill, then update front buffer
    -- so the diff below only needs to emit content cells (not 2000 bg cells).
    -- This is the ONLY gpu_fill allowed, and it only fires on bg color transitions.
    if bgChanged then
        fs.deviceControl(self._hIn, "gpu_fill",
            {1, 1, W, H, " ", clrFg, clrBg})
        for y = 1, H do
            local rc, rf, rb = fCh[y], fFg[y], fBg[y]
            for x = 1, W do
                rc[x] = _SPACE_BYTE; rf[x] = clrFg; rb[x] = clrBg
            end
        end
        -- Now front buffer matches the cleared screen exactly.
        -- Only rows with delta entries need processing.
        -- (No need to check prevDtyR — front is fully current.)
        for y in pairs(dtyR) do
            local dc = dCh[y]
            if not dc then goto nextBgRow end
            local df, db = dFg[y], dBg[y]
            local fc, ff, fb = fCh[y], fFg[y], fBg[y]

            if bRunGrp then
                local x = 1
                while x <= W do
                    local ch = dc[x]
                    if not ch then x = x + 1; goto contBg end
                    local cfg = df[x] or clrFg
                    local cbg = db[x] or clrBg
                    if ch == fc[x] and cfg == ff[x] and cbg == fb[x] then
                        x = x + 1; goto contBg
                    end
                    local sx, nR = x, 1
                    runBuf[1] = BCHAR[ch]
                    fc[x]=ch; ff[x]=cfg; fb[x]=cbg; x = x + 1
                    while x <= W and dc[x] do
                        local nfg = df[x] or clrFg
                        local nbg = db[x] or clrBg
                        if nfg ~= cfg or nbg ~= cbg then break end
                        if dc[x] == fc[x] and nfg == ff[x] and nbg == fb[x] then break end
                        nR=nR+1; runBuf[nR]=BCHAR[dc[x]]
                        fc[x]=dc[x]; ff[x]=nfg; fb[x]=nbg; x = x + 1
                    end
                    nB=nB+1
                    local e = bat[nB]
                    local s = table.concat(runBuf,"",1,nR)
                    if e then e[1]=sx;e[2]=y;e[3]=s;e[4]=cfg;e[5]=cbg
                    else bat[nB]={sx,y,s,cfg,cbg} end
                    ::contBg::
                end
            else
                for x = 1, W do
                    local ch = dc[x]
                    if ch then
                        local cfg = df[x] or clrFg
                        local cbg = db[x] or clrBg
                        if ch ~= fc[x] or cfg ~= ff[x] or cbg ~= fb[x] then
                            fc[x]=ch; ff[x]=cfg; fb[x]=cbg
                            nB=nB+1; local e = bat[nB]
                            if e then e[1]=x;e[2]=y;e[3]=BCHAR[ch];e[4]=cfg;e[5]=cbg
                            else bat[nB]={x,y,BCHAR[ch],cfg,cbg} end
                        end
                    end
                end
            end
            ::nextBgRow::
        end
        self._nB = nB
        return
    end

    -- ================================================================
    -- STEADY STATE: same bg color as last frame.
    -- Process two sets of rows:
    --   A) Current dirty rows → diff (delta or clear) vs front
    --   B) Previously dirty rows that are NOT current dirty
    --      → their old content must be replaced with clear color
    -- ================================================================

    -- Set A: current dirty rows
    for y in pairs(dtyR) do
        local dc = dCh[y]
        local df = dc and dFg[y] or nil
        local db = dc and dBg[y] or nil
        local fc, ff, fb = fCh[y], fFg[y], fBg[y]

        if bRunGrp then
            local x = 1
            while x <= W do
                -- Target: delta value or clear
                local tch, tfg, tbg
                if dc and dc[x] then
                    tch = dc[x]; tfg = df[x] or clrFg; tbg = db[x] or clrBg
                else
                    tch = _SPACE_BYTE; tfg = clrFg; tbg = clrBg
                end

                if tch == fc[x] and tfg == ff[x] and tbg == fb[x] then
                    x = x + 1
                else
                    -- Start run
                    local sx, runFg, runBg = x, tfg, tbg
                    local nR = 1; runBuf[1] = BCHAR[tch]
                    fc[x]=tch; ff[x]=tfg; fb[x]=tbg; x = x + 1

                    while x <= W do
                        local nch, nfg, nbg
                        if dc and dc[x] then
                            nch = dc[x]; nfg = df[x] or clrFg; nbg = db[x] or clrBg
                        else
                            nch = _SPACE_BYTE; nfg = clrFg; nbg = clrBg
                        end
                        if nfg ~= runFg or nbg ~= runBg then break end
                        if nch == fc[x] and nfg == ff[x] and nbg == fb[x] then
                            -- Unchanged — try gap bridge
                            local bridged = false
                            local pEnd = x + _GAP_MAX; if pEnd > W then pEnd = W end
                            for px = x + 1, pEnd do
                                local pch, pfg, pbg
                                if dc and dc[px] then
                                    pch=dc[px]; pfg=df[px] or clrFg; pbg=db[px] or clrBg
                                else
                                    pch=_SPACE_BYTE; pfg=clrFg; pbg=clrBg
                                end
                                if pfg ~= runFg or pbg ~= runBg then break end
                                if pch ~= fc[px] or pfg ~= ff[px] or pbg ~= fb[px] then
                                    -- Bridge gap cells
                                    for bx = x, px do
                                        nR = nR + 1
                                        local bc
                                        if dc and dc[bx] then bc = dc[bx]
                                        else bc = _SPACE_BYTE end
                                        runBuf[nR] = BCHAR[bc]
                                        fc[bx]=bc; ff[bx]=runFg; fb[bx]=runBg
                                    end
                                    x = px + 1; bridged = true; break
                                end
                            end
                            if not bridged then break end
                        else
                            nR=nR+1; runBuf[nR]=BCHAR[nch]
                            fc[x]=nch; ff[x]=nfg; fb[x]=nbg; x = x + 1
                        end
                    end

                    nB=nB+1; local e = bat[nB]
                    local s = table.concat(runBuf,"",1,nR)
                    if e then e[1]=sx;e[2]=y;e[3]=s;e[4]=runFg;e[5]=runBg
                    else bat[nB]={sx,y,s,runFg,runBg} end
                end
            end
        else
            for x = 1, W do
                local tch, tfg, tbg
                if dc and dc[x] then
                    tch=dc[x]; tfg=df[x] or clrFg; tbg=db[x] or clrBg
                else
                    tch=_SPACE_BYTE; tfg=clrFg; tbg=clrBg
                end
                if tch ~= fc[x] or tfg ~= ff[x] or tbg ~= fb[x] then
                    fc[x]=tch; ff[x]=tfg; fb[x]=tbg
                    nB=nB+1; local e = bat[nB]
                    if e then e[1]=x;e[2]=y;e[3]=BCHAR[tch];e[4]=tfg;e[5]=tbg
                    else bat[nB]={x,y,BCHAR[tch],tfg,tbg} end
                end
            end
        end
    end

    -- Set B: previously dirty rows that are NOT dirty this frame.
    -- These had content last frame but nothing was drawn on them this frame.
    -- They must revert to clear color.
    for y in pairs(prevDtyR) do
        if dtyR[y] then goto skipPrev end  -- already processed above
        local fc, ff, fb = fCh[y], fFg[y], fBg[y]

        if bRunGrp then
            local x = 1
            while x <= W do
                if fc[x] ~= _SPACE_BYTE or ff[x] ~= clrFg or fb[x] ~= clrBg then
                    local sx = x; local nR = 1
                    runBuf[1] = _BCHAR[_SPACE_BYTE]
                    fc[x]=_SPACE_BYTE; ff[x]=clrFg; fb[x]=clrBg; x = x + 1
                    while x <= W do
                        if fc[x] == _SPACE_BYTE and ff[x] == clrFg and fb[x] == clrBg then
                            break
                        end
                        nR=nR+1; runBuf[nR]=_BCHAR[_SPACE_BYTE]
                        fc[x]=_SPACE_BYTE; ff[x]=clrFg; fb[x]=clrBg; x = x + 1
                    end
                    nB=nB+1; local e = bat[nB]
                    local s = table.concat(runBuf,"",1,nR)
                    if e then e[1]=sx;e[2]=y;e[3]=s;e[4]=clrFg;e[5]=clrBg
                    else bat[nB]={sx,y,s,clrFg,clrBg} end
                else
                    x = x + 1
                end
            end
        else
            for x = 1, W do
                if fc[x] ~= _SPACE_BYTE or ff[x] ~= clrFg or fb[x] ~= clrBg then
                    fc[x]=_SPACE_BYTE; ff[x]=clrFg; fb[x]=clrBg
                    nB=nB+1; local e = bat[nB]
                    if e then e[1]=x;e[2]=y;e[3]=_BCHAR[_SPACE_BYTE];e[4]=clrFg;e[5]=clrBg
                    else bat[nB]={x,y,_BCHAR[_SPACE_BYTE],clrFg,clrBg} end
                end
            end
        end
        ::skipPrev::
    end

    self._nB = nB
end

function XE._M:setTheme(tTheme)
    self._theme = tTheme
end

function XE._M:c(sName)
    return self._theme[sName] or XE.FG
end

function XE._M:pushClip(x, y, w, h)
    local x1, y1 = x, y
    local x2, y2 = x + w - 1, y + h - 1
    -- Intersect with parent clip
    if self._nClip > 0 then
        local p = self._clipStack[self._nClip]
        if x1 < p[1] then x1 = p[1] end
        if y1 < p[2] then y1 = p[2] end
        if x2 > p[3] then x2 = p[3] end
        if y2 > p[4] then y2 = p[4] end
    else
        if x1 < 1 then x1 = 1 end
        if y1 < 1 then y1 = 1 end
        if x2 > self.W then x2 = self.W end
        if y2 > self.H then y2 = self.H end
    end
    self._nClip = self._nClip + 1
    self._clipStack[self._nClip] = {x1, y1, x2, y2}
end

function XE._M:popClip()
    if self._nClip > 0 then
        self._clipStack[self._nClip] = nil
        self._nClip = self._nClip - 1
    end
end

-- Returns: firstVisible, lastVisible, selectedIndex, contentWidth, bActivated
function XE._M:beginScroll(id, x, y, w, h, nTotalItems, nItemH)
    nItemH = nItemH or 1
    local hot = self:_regW(id)

    local st = self._scrollState[id]
    if not st then
        st = { off = 0, sel = 1 }
        self._scrollState[id] = st
    end

    local nVisItems = math.floor(h / nItemH)
    local nMaxOff = math.max(0, nTotalItems - nVisItems)

    -- Handle input when focused
    if hot and self._key then
        local k = self._key
        if k == "\27[A" then  -- Up
            st.sel = st.sel - 1
            if st.sel < 1 then st.sel = 1 end
            self._key = nil
        elseif k == "\27[B" then  -- Down
            st.sel = st.sel + 1
            if st.sel > nTotalItems then st.sel = nTotalItems end
            self._key = nil
        elseif k == "\27[5~" then  -- PgUp
            st.sel = math.max(1, st.sel - nVisItems)
            self._key = nil
        elseif k == "\27[6~" then  -- PgDn
            st.sel = math.min(nTotalItems, st.sel + nVisItems)
            self._key = nil
        elseif k == "\27[H" then  -- Home
            st.sel = 1
            self._key = nil
        elseif k == "\27[F" then  -- End
            st.sel = nTotalItems
            self._key = nil
        end
    end

    -- Ensure selection visible
    if st.sel < st.off + 1 then st.off = st.sel - 1 end
    if st.sel > st.off + nVisItems then st.off = st.sel - nVisItems end
    st.off = math.max(0, math.min(nMaxOff, st.off))

    local bHasBar = nTotalItems > nVisItems
    local nCW = bHasBar and (w - 1) or w

    self._activeScroll = {
        x = x, y = y, w = w, h = h,
        nTotal = nTotalItems, nVis = nVisItems,
        off = st.off, hasBar = bHasBar,
    }

    local nFirst = st.off + 1
    local nLast  = math.min(nTotalItems, st.off + nVisItems)
    local bAct   = hot and self._act

    -- Clip content area
    self:pushClip(x, y, nCW, h)

    return nFirst, nLast, st.sel, nCW, bAct
end

function XE._M:endScroll()
    self:popClip()
    local sc = self._activeScroll
    if not sc then return end
    self._activeScroll = nil

    -- Draw scrollbar on right edge
    if sc.hasBar and sc.nTotal > 0 then
        local sbX = sc.x + sc.w - 1
        local nBarH = sc.h
        local nThumbH = math.max(1, math.floor(nBarH * sc.nVis / sc.nTotal))
        local nRange  = math.max(1, sc.nTotal - sc.nVis)
        local nThumbY = sc.y + math.floor(sc.off / nRange * math.max(0, nBarH - nThumbH))

        local cThumb = self._theme.scroll_thumb or 0xAAAAAA
        local cTrack = self._theme.scroll_track or 0x555555
        local cBg    = self._theme.scroll_bg    or 0x111111

        for ry = sc.y, sc.y + nBarH - 1 do
            if ry >= nThumbY and ry < nThumbY + nThumbH then
                self:text(sbX, ry, "#", cThumb, cBg)
            else
                self:text(sbX, ry, "|", cTrack, cBg)
            end
        end
    end
end

-- Returns: currentValue, bChanged, bSubmitted
function XE._M:textInput(id, x, y, w, sValue, fg, bg, afg, abg)
    local hot = self:_regW(id)

    local st = self._inputState[id]
    if not st then
        st = { buf = sValue or "", cur = #(sValue or ""), sx = 0, ext = nil }
        self._inputState[id] = st
    end

    -- Sync with external value
    if sValue ~= nil and sValue ~= st.ext then
        st.buf = sValue; st.cur = #sValue; st.ext = sValue
    end

    local bChanged, bSubmit = false, false

    -- Capture input when focused
    if hot and self._key then
        local k = self._key
        if k == "\n" then
            bSubmit = true; self._key = nil
        elseif k == "\b" then
            if st.cur > 0 then
                st.buf = st.buf:sub(1,st.cur-1) .. st.buf:sub(st.cur+1)
                st.cur = st.cur - 1; bChanged = true
            end
            self._key = nil
        elseif k == "\27[D" then  -- Left
            if st.cur > 0 then st.cur = st.cur - 1 end
            self._key = nil
        elseif k == "\27[C" then  -- Right
            if st.cur < #st.buf then st.cur = st.cur + 1 end
            self._key = nil
        elseif k == "\27[H" then  -- Home
            st.cur = 0; self._key = nil
        elseif k == "\27[F" then  -- End
            st.cur = #st.buf; self._key = nil
        elseif #k == 1 and k:byte() >= 32 and k:byte() < 127 then
            st.buf = st.buf:sub(1,st.cur) .. k .. st.buf:sub(st.cur+1)
            st.cur = st.cur + 1; bChanged = true
            self._key = nil
        end
    end

    -- Scroll to keep cursor visible
    local nIW = w - 2
    if nIW < 1 then nIW = 1 end
    if st.cur - st.sx >= nIW then st.sx = st.cur - nIW + 1 end
    if st.cur < st.sx then st.sx = st.cur end

    -- Draw
    fg  = fg  or self._theme.input_fg  or XE.FG
    bg  = bg  or self._theme.input_bg  or 0x111133
    afg = afg or self._theme.input_afg or XE.FG
    abg = abg or self._theme.input_abg or 0x222255
    local uFg = hot and afg or fg
    local uBg = hot and abg or bg

    self:text(x, y, "[", uFg, uBg)
    local sVis = st.buf:sub(st.sx + 1, st.sx + nIW)
    if #sVis < nIW then sVis = sVis .. string.rep(" ", nIW - #sVis) end
    self:text(x + 1, y, sVis, uFg, uBg)
    self:text(x + w - 1, y, "]", uFg, uBg)

    -- Cursor overlay (inverted cell)
    if hot then
        local cX = x + 1 + (st.cur - st.sx)
        if cX >= x + 1 and cX < x + w - 1 then
            local cCh = (st.cur < #st.buf)
                and st.buf:sub(st.cur+1, st.cur+1) or " "
            self:text(cX, y, cCh, uBg, uFg)
        end
    end

    st.ext = st.buf
    return st.buf, bChanged, bSubmit
end

-- =============================================
-- SUSPEND / RESUME
-- suspend() nils buffer tables → GC frees RAM.
-- resume()  re-allocates fresh buffers → diff
-- engine sees everything as changed → full repaint.
-- =============================================

function XE._M:suspend()
    if self._suspended then return end
    self._suspended = true
    -- Nil heavy tables → GC frees RAM
    self._fCh = nil; self._fFg = nil; self._fBg = nil
    self._dCh = nil; self._dFg = nil; self._dBg = nil
    self._dtyR = nil; self._prevDtyR = nil
end

function XE._M:resume()
    if not self._suspended then return end
    self._suspended = false
    -- Must allocate fresh buffers (old ones were GC'd).
    -- _allocFrontBuffer sets _prevClearBg = _NOCLEAR,
    -- which forces bgChanged=true on next endFrame → gpu_fill.
    -- This is unavoidable: we lost the screen truth when we
    -- nil'd the front buffer, so we MUST resync via gpu_fill.
    self:_allocFrontBuffer()
end

function XE._M:isSuspended()
    return self._suspended
end

-- =============================================
-- PAGE MANAGER
-- Each page has its own buffers + widget state.
-- Only the active page has RAM-resident buffers.
-- Inactive pages are either:
--   a) nil'd (pure RAM savings), or
--   b) backed by a GPU snapshot (instant restore).
-- =============================================

function XE._M:createPage(sId)
    if self._pages[sId] then return false, "page exists" end
    self._pages[sId] = {
        -- Buffers: nil until first activation
        fCh = nil, fFg = nil, fBg = nil,
        -- Saved widget state
        wIds = {}, nW = 0, focIdx = 0, focId = nil,
        scrollState = {}, inputState = {},
        clipStack = {}, nClip = 0,
        activeScroll = nil,
        -- Saved clear state
        baseFg = self._baseFg, baseBg = self._baseBg,
        clearBg = _NOCLEAR, prevClearBg = _NOCLEAR,
        -- GPU snapshot buffer (nil = no snapshot)
        gpuBuf = nil,
        -- Has this page ever been rendered?
        virgin = true,
    }
    -- First page created becomes active automatically
    if not self._activePage then
        self._activePage = sId
        self._pages[sId].virgin = false
    end
    return true
end

function XE._M:_savePageState(sId)
    local pg = self._pages[sId]
    if not pg then return end
    -- Save widget state (persists across page switches)
    pg.wIds        = self._wIds
    pg.nW          = self._nW
    pg.focIdx      = self._focIdx
    pg.focId       = self._focId
    pg.scrollState = self._scrollState
    pg.inputState  = self._inputState
    pg.clipStack   = self._clipStack
    pg.nClip       = self._nClip
    pg.activeScroll= self._activeScroll
    pg.baseFg      = self._baseFg
    pg.baseBg      = self._baseBg
    -- Front buffer STAYS on context — it IS the screen truth.
    -- _clearBg/_prevClearBg stay too — they track clear state.
    -- 
    -- Drop buffer refs → GC frees ~48KB per page
    -- self._fCh = nil; self._fFg = nil; self._fBg = nil
    -- self._dCh = nil; self._dFg = nil; self._dBg = nil
    -- self._dtyR = nil; self._prevDtyR = nil
end


function XE._M:_loadPageState(sId)
    local pg = self._pages[sId]
    if not pg then return end

    --     self:_allocFrontBuffer()

    self._wIds         = pg.wIds        or {}
    self._nW           = pg.nW          or 0
    self._focIdx       = pg.focIdx      or 0
    self._focId        = pg.focId
    self._scrollState  = pg.scrollState or {}
    self._inputState   = pg.inputState  or {}
    self._clipStack    = pg.clipStack   or {}
    self._nClip        = pg.nClip       or 0
    self._activeScroll = pg.activeScroll
    self._baseFg       = pg.baseFg      or XE.FG
    self._baseBg       = pg.baseBg      or XE.BG
    pg.virgin = false
    -- NO _allocFrontBuffer. NO _prevClearBg reset.
    -- Front buffer already matches screen. Diff handles the rest.
end

function XE._M:switchPage(sId)
    if not self._pages[sId] then return false, "no such page" end
    if sId == self._activePage then return true end

    -- Save outgoing page (widget state only)
    if self._activePage then
        if self._bGpuBuf and self._ext.XE_ui_gpu_page_snapshot then
            self:_takePageSnapshot(self._activePage)
        end
        self:_savePageState(self._activePage)
    end

    -- The front buffer correctly represents what's on screen.
    -- We KEEP it. The diff engine compares new page's delta against
    -- old page's screen content and emits only differences.

    -- Mark ALL rows as "previously dirty".
    -- Set B in _flushWithClear will revert any row the new page
    -- doesn't draw on back to the clear color.
    local tAllDirty = {}
    for y = 1, self.H do tAllDirty[y] = true end
    self._prevDtyR = tAllDirty

    -- Fresh delta for new page
    self._dCh = {}; self._dFg = {}; self._dBg = {}
    self._dtyR = {}; self._nDty = 0
    self._nB = 0
    -- _clearBg stays as-is (carries the old page's bg value).
    -- beginFrame will copy it to _prevClearBg.
    -- If new page uses same bg → bgChanged=false → efficient diff.
    -- If different bg → bgChanged=true → gpu_fill (correct behavior).

    -- Load incoming page
    self._activePage = sId
    self:_loadPageState(sId)
    self._suspended = false
    return true
end

function XE._M:_takePageSnapshot(sId)
    if not self._bGpuBuf then return end
    local pg = self._pages[sId]
    if not pg then return end
    -- Allocate GPU buffer for this page if not already
    if not pg.gpuBuf then
        local bOk, nIdx = fs.deviceControl(self._hIn, "gpu_alloc_buffer",
            {self.W, self.H})
        if bOk and nIdx and nIdx > 0 then
            pg.gpuBuf = nIdx
        else
            return  -- GPU buffer allocation failed
        end
    end
    -- bitblt screen (buffer 0) → page's GPU buffer
    fs.deviceControl(self._hIn, "gpu_bitblt",
        {pg.gpuBuf, 1, 1, self.W, self.H, 0, 1, 1})
end

function XE._M:destroyPage(sId)
    local pg = self._pages[sId]
    if not pg then return false end
    -- Free GPU snapshot buffer
    if pg.gpuBuf and self._bGpuBuf then
        fs.deviceControl(self._hIn, "gpu_free_buffer", {pg.gpuBuf})
    end
    self._pages[sId] = nil
    if self._activePage == sId then
        self._activePage = nil
    end
    return true
end

function XE._M:getActivePage()
    return self._activePage
end

function XE._M:listPages()
    local t = {}
    for id, pg in pairs(self._pages) do
        t[#t + 1] = {
            id = id,
            active = (id == self._activePage),
            hasSnapshot = (pg.gpuBuf ~= nil),
            virgin = pg.virgin,
        }
    end
    return t
end

-- =============================================
-- 7. RENDERING PRIMITIVES
-- =============================================

-- ---- text(x, y, s, fg, bg) ----
-- Hot path. Two code paths: shadow-buffer vs direct-batch.

function XE._M:text(x, y, s, fg, bg)
    if self._suspended then return end
    local nLen = #s
    if nLen == 0 or y < 1 or y > self.H then return end
    fg = fg or self._baseFg
    bg = bg or self._baseBg

    local x1, x2 = x, x + nLen - 1
    if x1 < 1 then x1 = 1 end
    if x2 > self.W then x2 = self.W end

    -- Clip
    if self._nClip > 0 then
        local c = self._clipStack[self._nClip]
        if y < c[2] or y > c[4] then return end
        if x1 < c[1] then x1 = c[1] end
        if x2 > c[3] then x2 = c[3] end
    end
    if x1 > x2 then return end

    if self._bShadow then
        -- Shadow path: write bytes to sparse delta
        local dCh, dFg, dBg = self._dCh, self._dFg, self._dBg
        local rCh = dCh[y]
        local rFg, rBg
        if rCh then
            rFg = dFg[y]; rBg = dBg[y]
        else
            rCh = {}; rFg = {}; rBg = {}
            dCh[y] = rCh; dFg[y] = rFg; dBg[y] = rBg
        end

        local off = 1 - x  -- screen col → string byte index
        for cx = x1, x2 do
            rCh[cx] = s:byte(cx + off)
            rFg[cx] = fg
            rBg[cx] = bg
        end

        if not self._dtyR[y] then
            self._dtyR[y] = true
            self._nDty = self._nDty + 1
        end
    else
        -- Direct batch path: add string segment
        local sC = s
        if x1 ~= x or x2 ~= x + nLen - 1 then
            sC = s:sub(x1 - x + 1, x2 - x + 1)
        end
        local nB = self._nB + 1; self._nB = nB
        local e = self._bat[nB]
        if e then e[1]=x1;e[2]=y;e[3]=sC;e[4]=fg;e[5]=bg
        else self._bat[nB]={x1,y,sC,fg,bg} end
    end
end

-- ---- fill(x, y, w, h, ch, fg, bg) ----

function XE._M:fill(x, y, w, h, ch, fg, bg)
    if self._suspended then return end
    ch = ch or " "
    fg = fg or self._baseFg
    bg = bg or self._baseBg
    local x1 = x < 1 and 1 or x
    local y1 = y < 1 and 1 or y
    local x2 = x + w - 1; if x2 > self.W then x2 = self.W end
    local y2 = y + h - 1; if y2 > self.H then y2 = self.H end

    if self._nClip > 0 then
        local c = self._clipStack[self._nClip]
        if x1 < c[1] then x1 = c[1] end
        if y1 < c[2] then y1 = c[2] end
        if x2 > c[3] then x2 = c[3] end
        if y2 > c[4] then y2 = c[4] end
    end
    if x1 > x2 or y1 > y2 then return end

    local nW = x2 - x1 + 1
    local c1b = ch:byte(1)

    if self._bShadow then
        -- Always write to delta — diff engine handles the rest.
        -- NEVER gpu_fill in shadow mode (causes flash).
        local dCh, dFg, dBg = self._dCh, self._dFg, self._dBg
        local dtyR = self._dtyR
        for ry = y1, y2 do
            local rCh = dCh[ry]
            local rFg, rBg
            if rCh then rFg = dFg[ry]; rBg = dBg[ry]
            else
                rCh = {}; rFg = {}; rBg = {}
                dCh[ry] = rCh; dFg[ry] = rFg; dBg[ry] = rBg
            end
            for rx = x1, x2 do
                rCh[rx] = c1b; rFg[rx] = fg; rBg[rx] = bg
            end
            if not dtyR[ry] then
                dtyR[ry] = true
                self._nDty = self._nDty + 1
            end
        end
    else
        -- Direct mode: large fills use gpu_fill
        local nArea = nW * (y2 - y1 + 1)
        if nArea >= _FILL_GPU_THRESHOLD then
            fs.deviceControl(self._hIn, "gpu_fill",
                {x1, y1, nW, y2-y1+1, ch:sub(1,1), fg, bg})
            return
        end
        local sRow = (c1b == _SPACE_BYTE and self._spCache[nW])
                     or string.rep(ch:sub(1,1), nW)
        local bat, nB = self._bat, self._nB
        for ry = y1, y2 do
            nB = nB + 1
            local e = bat[nB]
            if e then e[1]=x1;e[2]=ry;e[3]=sRow;e[4]=fg;e[5]=bg
            else bat[nB]={x1,ry,sRow,fg,bg} end
        end
        self._nB = nB
    end
end

-- ---- clear(bg) ----

--[[
function XE._M:clear(bg)
    bg = bg or XE.BG
    if self._bDefer then
        self._clearQ = bg
        -- Wipe stale delta
        local dCh, dFg, dBg = self._dCh, self._dFg, self._dBg
        local dtyR = self._dtyR
        for y in pairs(dtyR) do
            dCh[y]=nil; dFg[y]=nil; dBg[y]=nil; dtyR[y]=nil
        end
        self._nDty = 0; self._nB = 0
    else
        -- Immediate gpu_fill
        fs.deviceControl(self._hIn, "gpu_fill",
            {1, 1, self.W, self.H, " ", self._baseFg, bg})
        self._baseBg = bg
        if self._bShadow then
            local dfg = self._baseFg
            local fCh, fFg, fBg = self._fCh, self._fFg, self._fBg
            for y = 1, self.H do
                local rCh, rFg, rBg = fCh[y], fFg[y], fBg[y]
                for x = 1, self.W do
                    rCh[x] = _SPACE_BYTE; rFg[x] = dfg; rBg[x] = bg
                end
            end
        end
        local dCh, dFg, dBg = self._dCh, self._dFg, self._dBg
        local dtyR = self._dtyR
        for y in pairs(dtyR) do
            dCh[y]=nil; dFg[y]=nil; dBg[y]=nil; dtyR[y]=nil
        end
        self._nDty = 0; self._nB = 0
    end
end
--]]

function XE._M:clear(bg)
    if self._suspended then return end
    bg = bg or XE.BG
    self._baseBg = bg

    if self._bShadow then
        -- Record intent only. No gpu_fill. No front buffer reset.
        -- endFrame()'s _flushWithClear will treat uncovered cells as (SPACE, baseFg, bg)
        -- and diff against the front buffer — emitting only actual changes.
        self._clearBg = bg
    else
        -- Non-shadow mode: no front buffer to diff against, must gpu_fill
        fs.deviceControl(self._hIn, "gpu_fill",
            {1, 1, self.W, self.H, " ", self._baseFg, bg})
        self._nB = 0
    end
end

-- ---- hline / vline ----

function XE._M:hline(x, y, w, ch, fg, bg)
    if w > 0 then self:text(x, y, string.rep(ch or "-", w), fg, bg) end
end

function XE._M:vline(x, y, h, ch, fg, bg)
    local c = (ch or "|"):sub(1, 1)
    local yMax = y + h - 1; if yMax > self.H then yMax = self.H end
    for ry = y, yMax do self:text(x, ry, c, fg, bg) end
end

-- ---- box(x, y, w, h, title, fg, bg, bfg) ----

function XE._M:box(x, y, w, h, title, fg, bg, bfg)
    if w < 2 or h < 2 then return end
    fg  = fg  or self._baseFg
    bg  = bg  or self._baseBg
    bfg = bfg or fg
    -- Fill interior
    self:fill(x, y, w, h, " ", fg, bg)
    -- Top & bottom borders
    local hor = "+" .. string.rep("-", w - 2) .. "+"
    self:text(x, y,         hor, bfg, bg)
    self:text(x, y + h - 1, hor, bfg, bg)
    -- Side borders
    for ry = y + 1, y + h - 2 do
        self:text(x,         ry, "|", bfg, bg)
        self:text(x + w - 1, ry, "|", bfg, bg)
    end
    -- Title
    if title and #title > 0 then
        self:text(x + 2, y, " " .. title .. " ", bg, bfg)
    end
end

-- ---- progress(x, y, w, pct, fg, bg, ffg, fbg) ----

function XE._M:progress(x, y, w, pct, fg, bg, ffg, fbg)
    bg  = bg  or 0x222233
    fbg = fbg or 0x00AA44
    pct = pct or 0
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
    local nF = math.floor(pct / 100 * w)
    if nF > 0 then self:fill(x, y, nF, 1, " ", ffg or XE.FG, fbg) end
    if nF < w then self:fill(x + nF, y, w - nF, 1, " ", fg or XE.FG, bg) end
end

-- =============================================
-- 8. INPUT
-- =============================================

function XE._M:key()
    return self._key
end

-- =============================================
-- 9. IMGUI WIDGETS
-- (only functional when XE_ui_imgui_navigation is enabled)
-- =============================================

function XE._M:_regW(id)
    if not self._bImgui then return false end
    self._nW = self._nW + 1
    self._wIds[self._nW] = id
    if self._nW == 1 and not self._focId then
        self._focIdx = 1
        self._focId  = id
    end
    return self._focId == id
end

function XE._M:button(id, x, y, label, fg, bg, hfg, hbg)
    local hot = self:_regW(id)
    fg  = fg  or XE.FG;     bg  = bg  or 0x333366
    hfg = hfg or 0x000000;  hbg = hbg or 0xFFFF00
    self:text(x, y, label, hot and hfg or fg, hot and hbg or bg)
    return hot and self._act
end

function XE._M:selectable(id, x, y, w, label, fg, bg, sfg, sbg)
    local hot = self:_regW(id)
    fg  = fg  or XE.FG;     bg  = bg  or self._baseBg
    sfg = sfg or 0x000000;  sbg = sbg or 0xFFFF00
    local s = label or ""
    if #s < w then s = s .. string.rep(" ", w - #s) end
    if #s > w then s = s:sub(1, w) end
    self:text(x, y, s, hot and sfg or fg, hot and sbg or bg)
    return hot and self._act
end

function XE._M:label(x, y, s, fg)
    self:text(x, y, s, fg or 0xAAAAAA)
end

-- Returns: newCheckedState, bToggled
function XE._M:checkbox(id, x, y, bChecked, sLabel, fg, bg, hfg, hbg)
    local hot = self:_regW(id)
    fg  = fg  or self:c("fg");     bg  = bg  or self._baseBg
    hfg = hfg or self:c("sel_fg"); hbg = hbg or self:c("sel_bg")

    local sBox = bChecked and "[X] " or "[ ] "
    local sText = sBox .. (sLabel or "")
    self:text(x, y, sText, hot and hfg or fg, hot and hbg or bg)

    if hot and self._act then
        return not bChecked, true
    end
    return bChecked, false
end

-- Formatted text (like sprintf to screen)
function XE._M:textf(x, y, fg, bg, sFmt, ...)
    self:text(x, y, string.format(sFmt, ...), fg, bg)
end

-- Quick check: was there any keyboard input this frame?
function XE._M:hasInput()
    return self._key ~= nil or self._act
end

-- Horizontal separator line
function XE._M:separator(x, y, w, fg)
    self:text(x, y, string.rep("-", w), fg or self:c("border"))
end

-- Padded text (fills remaining width with spaces — for list rows)
function XE._M:textPad(x, y, w, s, fg, bg)
    if #s > w then s = s:sub(1, w) end
    if #s < w then
        local pad = self._spCache[w - #s]
        if pad then s = s .. pad else s = s .. string.rep(" ", w - #s) end
    end
    self:text(x, y, s, fg, bg)
end

return XE