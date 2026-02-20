

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
-- GRAPHICAL CHARACTER TABLE
-- Byte values 128+ map to unicode block elements.
-- The delta buffer stores these as single byte IDs;
-- _BCHAR converts them to multi-byte UTF-8 strings
-- only when building the final batch for gpu.set().
-- The GPU is unicode-aware: "▀▀A" = 3 cells, not 7.
-- =============================================

local _uc = unicode and unicode.char or function(n)
    -- Fallback UTF-8 encoder for BMP codepoints
    if n < 0x80 then return string.char(n) end
    if n < 0x800 then
        return string.char(0xC0 + math.floor(n / 64), 0x80 + n % 64)
    end
    return string.char(
        0xE0 + math.floor(n / 4096),
        0x80 + math.floor(n / 64) % 64,
        0x80 + n % 64)
end

-- Half-block canvas characters
_BCHAR[128] = _uc(0x2580)  -- ▀ UPPER HALF BLOCK (fg=top, bg=bottom)
_BCHAR[129] = _uc(0x2588)  -- █ FULL BLOCK (fg=color, bg=color)

-- Sparkline bar characters (bottom-aligned, 1/8 to 8/8)
_BCHAR[130] = _uc(0x2581)  -- ▁ 1/8
_BCHAR[131] = _uc(0x2582)  -- ▂ 2/8
_BCHAR[132] = _uc(0x2583)  -- ▃ 3/8
_BCHAR[133] = _uc(0x2584)  -- ▄ 4/8
_BCHAR[134] = _uc(0x2585)  -- ▅ 5/8
_BCHAR[135] = _uc(0x2586)  -- ▆ 6/8
_BCHAR[136] = _uc(0x2587)  -- ▇ 7/8
_BCHAR[137] = _uc(0x2588)  -- █ 8/8

-- Constants for canvas cell encoding
local _HALF_BLOCK = 128   -- ▀: top≠bottom
local _FULL_BLOCK = 129   -- █: top==bottom, both non-bg

-- =============================================
-- RING BUFFER TIME SERIES
-- O(1) push, O(1) random access.
-- Replaces table.remove(t, 1) pattern which is O(n).
--
-- Usage:
--   local ts = XE.timeSeries(120)
--   ts:push(42.5)
--   print(ts:len())     -- 1
--   print(ts:get(1))    -- 42.5
-- =============================================

function XE.timeSeries(nMax)
    return {
        _buf  = {},
        _head = 0,
        _len  = 0,
        _max  = nMax,
        push = function(self, v)
            self._head = self._head % self._max + 1
            self._buf[self._head] = v
            if self._len < self._max then self._len = self._len + 1 end
        end,
        len = function(self) return self._len end,
        get = function(self, i)
            return self._buf[((self._head - self._len + i - 1) % self._max) + 1]
        end,
    }
end

-- Inline data accessors — used by all graph functions.
-- Detect timeSeries by _buf field. Plain arrays use raw index.
local function _dLen(d) return d._len or #d end
local function _dGet(d, i)
    local b = d._buf
    if b then return b[((d._head - d._len + i - 1) % d._max) + 1] end
    return d[i]
end

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
    "XE_ui_graph_canvas",
    "XE_ui_graph_api",
    "XE_ui_modal",
    "XE_ui_modal_prebuilt",
    "XE_ui_toast",
    "XE_ui_dropdown",
    "XE_ui_command_palette",
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
    -- Graph dependencies
    if ext.XE_ui_graph_api then
        ext.XE_ui_graph_canvas = true
    end
    if ext.XE_ui_graph_canvas then
        -- Canvas needs shadow buffer for delta writes
        if not ext.XE_ui_shadow_buffering_render_batch
           and not ext.XE_ui_shadow_buffering_generic_render then
            ext.XE_ui_shadow_buffering_render_batch = true
        end
        if not ext.XE_ui_dirty_row_tracking then
            ext.XE_ui_dirty_row_tracking = true
        end
    end

    if ext.XE_ui_page_manager then
        ext.XE_ui_suspend_resume = true
    end
    if ext.XE_ui_gpu_page_snapshot then
        ext.XE_ui_gpu_double_buffer = true
        ext.XE_ui_suspend_resume = true
    end

    -- Modal dependencies
    if ext.XE_ui_modal_prebuilt then ext.XE_ui_modal = true end
    if ext.XE_ui_dropdown then ext.XE_ui_modal = true end
    if ext.XE_ui_command_palette then
        ext.XE_ui_modal = true
        ext.XE_ui_imgui_navigation = true
    end
    if ext.XE_ui_modal then
        ext.XE_ui_imgui_navigation = true
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

        -- ===== Suspend/Resume =====
        _suspended = false,

        -- ===== Page Manager =====
        _pages = {},
        _activePage = nil,

        -- ===== GPU Double Buffer =====
        _gpuBufId = nil,     -- off-screen buffer index (nil = not available)
        _bGpuBuf = false,    -- GPU buffers supported?

        -- ===== GPU Page Snapshots =====
        _gpuPageBufs = {},   -- pageId → GPU buffer index
        _canvases = {},

        -- Modal system
        _modalStack    = {},    -- ordered modal ids (bottom → top)
        _modals        = {},    -- id → modal state
        _topModal      = nil,   -- id of topmost modal (nil = no modal)
        _insideModal   = false, -- true between beginModal/endModal
        _modalSnapshots= {},    -- id → saved front buffer (dim mode only)

        -- Toast system
        _toasts     = {},       -- {msg, fg, bg, deadline, width}
        _toastMax   = 5,
        _toastPos   = "tr",     -- "tr" = top-right, "br" = bottom-right

        -- Dropdown state
        _dropdowns = {},

        -- Command palette state
        _palette = nil,
        _mouseX = nil, _mouseY = nil, _mouseBtn = nil,
        _mouseClicked = false,
        _scrollDelta = nil, _scrollX = nil, _scrollY = nil,
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

    -- ===== Probe GPU buffer support =====
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

    -- Reset per-frame mouse state
    self._mouseX = nil; self._mouseY = nil
    self._mouseBtn = nil; self._mouseClicked = false
    self._scrollDelta = nil; self._scrollX = nil; self._scrollY = nil
    self._pendingDropdown = nil

    if self._first then
        self._key = nil; self._first = false
    else
        self._key = fs.read(self._hIn)
        if not self._key then _fSysYield() end
    end

    -- ---- Parse mouse/scroll events from encoded sequences ----
    local k = self._key
    if k and #k > 4 and k:sub(1, 3) == "\27[<" and k:sub(-1) == "M" then
        local sData = k:sub(4, -2)  -- strip \27[< and M
        local sBtn, sX, sY = sData:match("^(%d+);(%d+);(%d+)$")
        if sBtn then
            local nBtn = tonumber(sBtn)
            local nX   = tonumber(sX)
            local nY   = tonumber(sY)
            if nBtn == 64 then
                -- Scroll up
                self._scrollDelta = -1
                self._scrollX = nX; self._scrollY = nY
            elseif nBtn == 65 then
                -- Scroll down
                self._scrollDelta = 1
                self._scrollX = nX; self._scrollY = nY
            elseif nBtn < 32 then
                -- Click (0=left, 1=right, 2=middle)
                self._mouseX = nX; self._mouseY = nY
                self._mouseBtn = nBtn; self._mouseClicked = true
            end
            -- Drag (32+) — store position but don't activate
            if nBtn >= 32 and nBtn < 64 then
                self._mouseX = nX; self._mouseY = nY
                self._mouseBtn = nBtn - 32
            end
        end
        self._key = nil  -- consume mouse event (not a keyboard key)
    end

    self._act = false

    if self._bImgui then
        local bDDOpen = false
        if self._dropdowns then
            for _, dd in pairs(self._dropdowns) do
                if dd.open then bDDOpen = true; break end
            end
        end

        -- Close open dropdown on click outside (handled here before widgets)
        if bDDOpen and self._mouseClicked then
            local pd = self._pendingDropdown
            -- If no pending dropdown was rendered last frame at click pos,
            -- the dropdown will close itself in its own method below.
        end

        local kk = self._key
        if kk and not bDDOpen then
            if kk == "\t" then
                if self._nW > 0 then
                    self._focIdx = (self._focIdx % self._nW) + 1
                    self._focId  = self._wIds[self._focIdx]
                end
                self._key = nil
            elseif kk == "\27[Z" then
                -- Shift+Tab: previous widget
                if self._nW > 0 then
                    self._focIdx = self._focIdx - 1
                    if self._focIdx < 1 then self._focIdx = self._nW end
                    self._focId = self._wIds[self._focIdx]
                end
                self._key = nil
            elseif kk == "\n" then
                self._act = true
            elseif kk == "\27" and self._topModal then
                local tM = self._modals[self._topModal]
                if tM and not tM.closed and not tM.noEsc then
                    tM.closed = true; tM.result = nil
                end
                self._key = nil
            end
        elseif kk and bDDOpen then
            if kk == "\27" then
                for _, dd in pairs(self._dropdowns) do
                    if dd.open then dd.open = false; break end
                end
                self._key = nil
            end
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

    return self._key ~= nil or self._mouseClicked or self._scrollDelta ~= nil
end

function XE._M:_hitTest(id, x, y, w, h)
    if not self._mouseClicked then return false end
    local mx, my = self._mouseX, self._mouseY
    if not mx or not my then return false end
    w = w or 1; h = h or 1
    if mx >= x and mx < x + w and my >= y and my < y + h then
        self._focId = id
        -- Find widget index in registration list
        for i = self._nW, 1, -1 do
            if self._wIds[i] == id then self._focIdx = i; break end
        end
        self._mouseClicked = false  -- consume
        return true
    end
    return false
end

-- Mouse position query (for custom widgets)
function XE._M:mouse()
    return self._mouseX, self._mouseY, self._mouseBtn, self._mouseClicked
end

function XE._M:scroll()
    return self._scrollDelta, self._scrollX, self._scrollY
end

function XE._M:endFrame()
    if self._suspended then return end

    -- ===== IMGUI focus resolution =====
    if self._bImgui and self._nW > 0 then
        local found = false
        local wIds, focId = self._wIds, self._focId
        for i = 1, self._nW do
            if wIds[i] == focId then found = true; self._focIdx = i; break end
        end
        if not found then self._focIdx = 1; self._focId = wIds[1] end
    end

    -- ===== RENDER OVERLAYS INTO DELTA (before diff) =====

    -- Toasts
    if #self._toasts > 0 then
        self:_renderToasts()
    end

    -- Pending dropdown popup
    if self._pendingDropdown then
        local pd = self._pendingDropdown
        for i = 1, pd.nVis do
            local idx = pd.off + i
            if idx > #pd.options then break end
            local bSel = (idx == pd.sel)
            self:textPad(pd.x, pd.y + i - 1, pd.w,
                " " .. pd.options[idx],
                bSel and self:c("sel_fg") or self:c("fg"),
                bSel and self:c("sel_bg") or self:c("input_bg"))
        end
        self._pendingDropdown = nil
    end

    -- ===== DIFF + FLUSH =====
    if self._bShadow then
        local hasClear = (self._clearBg ~= _NOCLEAR)
        if hasClear then
            self:_flushWithClear()
        else
            if self._nDty == 0 then
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

    -- ===== EMIT BATCH =====
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

    -- ===== GPU DOUBLE BUFFER =====
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

    -- Keyboard input when focused
    if hot and self._key then
        local k = self._key
        if k == "\27[A" then
            st.sel = math.max(1, st.sel - 1); self._key = nil
        elseif k == "\27[B" then
            st.sel = math.min(nTotalItems, st.sel + 1); self._key = nil
        elseif k == "\27[5~" then
            st.sel = math.max(1, st.sel - nVisItems); self._key = nil
        elseif k == "\27[6~" then
            st.sel = math.min(nTotalItems, st.sel + nVisItems); self._key = nil
        elseif k == "\27[H" then
            st.sel = 1; self._key = nil
        elseif k == "\27[F" then
            st.sel = nTotalItems; self._key = nil
        end
    end

    -- Mouse click on list item
    if self._mouseClicked then
        local mx, my = self._mouseX, self._mouseY
        if mx and mx >= x and mx < x + w and my >= y and my < y + h then
            local nClickedRow = my - y
            local nClickedItem = st.off + math.floor(nClickedRow / nItemH) + 1
            if nClickedItem >= 1 and nClickedItem <= nTotalItems then
                st.sel = nClickedItem
                -- Set focus to this scroll widget
                self._focId = id
                for i = self._nW, 1, -1 do
                    if self._wIds[i] == id then self._focIdx = i; break end
                end
                self._mouseClicked = false
                hot = true
            end
        end
    end

    -- Scroll wheel within list bounds
    if self._scrollDelta then
        local sx, sy = self._scrollX, self._scrollY
        if sx and sx >= x and sx < x + w and sy >= y and sy < y + h then
            if self._scrollDelta < 0 then
                st.sel = math.max(1, st.sel - 3)
            else
                st.sel = math.min(nTotalItems, st.sel + 3)
            end
            self._scrollDelta = nil  -- consume
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
    if self:_hitTest(id, x, y, w, 1) then hot = true end

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
    -- When a modal is open, only widgets INSIDE the modal register.
    -- Widgets outside still render (for visual) but can't receive focus.
    if self._topModal and not self._insideModal then
        return false
    end
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
    -- Mouse click activation
    if self:_hitTest(id, x, y, #label, 1) then
        hot = true; self._act = true
    end
    fg  = fg  or XE.FG;     bg  = bg  or 0x333366
    hfg = hfg or 0x000000;  hbg = hbg or 0xFFFF00
    self:text(x, y, label, hot and hfg or fg, hot and hbg or bg)
    return hot and self._act
end

function XE._M:selectable(id, x, y, w, label, fg, bg, sfg, sbg)
    local hot = self:_regW(id)
    if self:_hitTest(id, x, y, w, 1) then
        hot = true; self._act = true
    end
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
    local sText = (bChecked and "[X] " or "[ ] ") .. (sLabel or "")
    if self:_hitTest(id, x, y, #sText, 1) then
        hot = true; self._act = true
    end
    fg  = fg  or self:c("fg");     bg  = bg  or self._baseBg
    hfg = hfg or self:c("sel_fg"); hbg = hbg or self:c("sel_bg")
    self:text(x, y, sText, hot and hfg or fg, hot and hbg or bg)
    if hot and self._act then return not bChecked, true end
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

-- =============================================
-- HALF-BLOCK PIXEL CANVAS
--
-- Resolution: w × (h*2) pixels in a w × h cell region.
-- Each screen cell encodes two vertical pixels via ▀:
--   fg = top pixel color, bg = bottom pixel color.
--
-- Pixel buffer is SPARSE: pix[py] = nil or {[px]=color}.
-- Only non-background pixels consume memory.
--
-- flush() writes directly to the context's delta buffer.
-- The diff engine handles the rest — only changed cells
-- reach the GPU.
-- =============================================

local _cv_mt = {}
_cv_mt.__index = _cv_mt

function XE._M:canvas(sId, x, y, w, h, bgColor)
    if self._suspended then return nil end
    local cv = self._canvases[sId]
    if not cv then
        cv = setmetatable({}, _cv_mt)
        self._canvases[sId] = cv
    end
    cv._ctx  = self
    cv._sx   = x
    cv._sy   = y
    cv._w    = w    -- screen columns
    cv._h    = h    -- screen rows
    cv._pixW = w            -- pixel width
    cv._pixH = h * 2        -- pixel height (2x vertical)
    cv._bg   = bgColor or self._baseBg
    if not cv._pix then cv._pix = {} end
    return cv
end

-- Clear all pixels to background
function _cv_mt:clear(bgColor)
    if bgColor then self._bg = bgColor end
    -- Nil every row reference → GC collects pixel data.
    -- Faster than iterating: O(nRows), not O(nPixels).
    local pix = self._pix
    for k in pairs(pix) do pix[k] = nil end
end

-- Set a single pixel (0-indexed coordinates)
function _cv_mt:pixel(px, py, color)
    if px < 0 or px >= self._pixW or py < 0 or py >= self._pixH then return end
    local pix = self._pix
    local row = pix[py]
    if not row then row = {}; pix[py] = row end
    row[px] = color
end

-- Fast horizontal line
function _cv_mt:hline(py, px1, px2, color)
    if py < 0 or py >= self._pixH then return end
    if px1 > px2 then px1, px2 = px2, px1 end
    if px1 < 0 then px1 = 0 end
    if px2 >= self._pixW then px2 = self._pixW - 1 end
    local pix = self._pix
    local row = pix[py]
    if not row then row = {}; pix[py] = row end
    for x = px1, px2 do row[x] = color end
end

-- Fast vertical line
function _cv_mt:vline(px, py1, py2, color)
    if px < 0 or px >= self._pixW then return end
    if py1 > py2 then py1, py2 = py2, py1 end
    if py1 < 0 then py1 = 0 end
    if py2 >= self._pixH then py2 = self._pixH - 1 end
    local pix = self._pix
    for y = py1, py2 do
        local row = pix[y]
        if not row then row = {}; pix[y] = row end
        row[px] = color
    end
end

-- Bresenham line (integer arithmetic, no floats)
function _cv_mt:line(x1, y1, x2, y2, color)
    local dx = x2 - x1; if dx < 0 then dx = -dx end
    local dy = y2 - y1; if dy < 0 then dy = -dy end
    local sx = x1 < x2 and 1 or -1
    local sy = y1 < y2 and 1 or -1
    local err = dx - dy
    local pix = self._pix
    local pw, ph = self._pixW, self._pixH
    while true do
        if x1 >= 0 and x1 < pw and y1 >= 0 and y1 < ph then
            local row = pix[y1]
            if not row then row = {}; pix[y1] = row end
            row[x1] = color
        end
        if x1 == x2 and y1 == y2 then break end
        local e2 = err + err
        if e2 > -dy then err = err - dy; x1 = x1 + sx end
        if e2 <  dx then err = err + dx; y1 = y1 + sy end
    end
end

-- Filled rectangle
function _cv_mt:fillRect(px, py, pw, ph, color)
    local x2 = px + pw - 1
    local y2 = py + ph - 1
    if px < 0 then px = 0 end
    if py < 0 then py = 0 end
    if x2 >= self._pixW then x2 = self._pixW - 1 end
    if y2 >= self._pixH then y2 = self._pixH - 1 end
    local pix = self._pix
    for y = py, y2 do
        local row = pix[y]
        if not row then row = {}; pix[y] = row end
        for x = px, x2 do row[x] = color end
    end
end

-- Outline rectangle
function _cv_mt:rect(px, py, pw, ph, color)
    self:hline(py, px, px + pw - 1, color)
    self:hline(py + ph - 1, px, px + pw - 1, color)
    self:vline(px, py, py + ph - 1, color)
    self:vline(px + pw - 1, py, py + ph - 1, color)
end

-- =============================================
-- CANVAS FLUSH — compile pixels to delta buffer
--
-- For each screen cell, packs two vertical pixels
-- into one half-block character:
--   top==bottom==bg  →  space (byte 32)
--   top==bottom!=bg  →  █ (byte 129), fg=color
--   top!=bottom      →  ▀ (byte 128), fg=top, bg=bottom
--
-- Cost: 6 ops per cell (2 lookups + 1 compare + 3 writes).
-- 40×10 canvas = 400 cells = ~2400 ops = <1ms in OC Lua.
-- =============================================

function _cv_mt:flush()
    local ctx = self._ctx
    if ctx._suspended then return end

    local pix  = self._pix
    local bgC  = self._bg
    local sx   = self._sx
    local sy   = self._sy
    local cw   = self._w
    local ch   = self._h
    local ctxW = ctx.W
    local ctxH = ctx.H
    local baseFg = ctx._baseFg

    local dCh  = ctx._dCh
    local dFg  = ctx._dFg
    local dBg  = ctx._dBg
    local dtyR = ctx._dtyR

    for cy = 1, ch do
        local dy = sy + cy - 1
        if dy < 1 or dy > ctxH then goto nextRow end

        local py_t = cy + cy - 1   -- cy*2-1
        local py_b = py_t + 1      -- cy*2
        local topR = pix[py_t]     -- nil = empty row
        local botR = pix[py_b]

        -- Get or create delta row
        local rCh = dCh[dy]
        local rFg, rBg
        if rCh then
            rFg = dFg[dy]; rBg = dBg[dy]
        else
            rCh = {}; rFg = {}; rBg = {}
            dCh[dy] = rCh; dFg[dy] = rFg; dBg[dy] = rBg
        end

        for cx = 1, cw do
            local dx = sx + cx - 1
            if dx < 1 or dx > ctxW then goto nextCol end

            local tc = topR and topR[cx - 1] or bgC
            local bc = botR and botR[cx - 1] or bgC

            if tc == bc then
                if tc == bgC then
                    rCh[dx] = _SPACE_BYTE
                    rFg[dx] = baseFg
                    rBg[dx] = bgC
                else
                    rCh[dx] = _FULL_BLOCK
                    rFg[dx] = tc
                    rBg[dx] = tc
                end
            else
                rCh[dx] = _HALF_BLOCK
                rFg[dx] = tc
                rBg[dx] = bc
            end

            ::nextCol::
        end

        if not dtyR[dy] then
            dtyR[dy] = true
            ctx._nDty = ctx._nDty + 1
        end

        ::nextRow::
    end
end

-- =============================================
-- SPARKLINE — single-row bar chart
-- Uses ▁▂▃▄▅▆▇█ characters (8 height levels).
-- Writes directly to delta buffer: zero allocation,
-- zero canvas overhead, just a tight loop.
--
-- tData = {3, 7, 2, 9, 1, ...}
-- Shows the LAST w values, right-aligned.
-- =============================================

function XE._M:sparkline(x, y, w, tData, fg, bg)
    if self._suspended then return end
    fg = fg or self:c("accent")
    bg = bg or self._baseBg

    local nData = _dLen(tData)
    if nData == 0 then
        self:fill(x, y, w, 1, " ", fg, bg); return
    end

    local minV, maxV = _dGet(tData, 1), _dGet(tData, 1)
    for i = 2, nData do
        local v = _dGet(tData, i)
        if v < minV then minV = v end
        if v > maxV then maxV = v end
    end
    if minV == maxV then maxV = minV + 1 end
    local inv8 = 8 / (maxV - minV)

    local nStart = math.max(1, nData - w + 1)

    local dCh = self._dCh
    local dFg = self._dFg
    local dBg = self._dBg
    local rCh = dCh[y]
    local rFg, rBg
    if rCh then rFg = dFg[y]; rBg = dBg[y]
    else
        rCh = {}; rFg = {}; rBg = {}
        dCh[y] = rCh; dFg[y] = rFg; dBg[y] = rBg
    end

    local nLeading = w - (nData - nStart + 1)
    for col = x, x + nLeading - 1 do
        if col >= 1 and col <= self.W then
            rCh[col] = _SPACE_BYTE; rFg[col] = fg; rBg[col] = bg
        end
    end

    local col = x + nLeading
    for i = nStart, nData do
        if col > x + w - 1 or col > self.W then break end
        if col >= 1 then
            local nLevel = math.floor((_dGet(tData, i) - minV) * inv8 + 0.5)
            if nLevel < 0 then nLevel = 0 end
            if nLevel > 8 then nLevel = 8 end
            if nLevel == 0 then rCh[col] = _SPACE_BYTE
            else rCh[col] = 129 + nLevel end
            rFg[col] = fg; rBg[col] = bg
        end
        col = col + 1
    end

    if not self._dtyR[y] then
        self._dtyR[y] = true; self._nDty = self._nDty + 1
    end
end

-- =============================================
-- LINE GRAPH
-- Plots tData as a connected line on a pixel canvas.
-- Auto-scales Y axis. Optional grid, fill, labels.
-- =============================================

function XE._M:lineGraph(sId, x, y, w, h, tData, tOpts)
    if self._suspended then return end
    tOpts = tOpts or {}

    local cv = self:canvas(sId, x, y, w, h, tOpts.bgColor or self._baseBg)
    cv:clear()

    local nData = _dLen(tData)
    if nData == 0 then cv:flush(); return end

    local pw, ph = cv._pixW, cv._pixH
    local color  = tOpts.color or 0x55FF55

    local minY = tOpts.minY
    local maxY = tOpts.maxY
    if not minY or not maxY then
        minY = _dGet(tData, 1); maxY = minY
        for i = 2, nData do
            local v = _dGet(tData, i)
            if v < minY then minY = v end
            if v > maxY then maxY = v end
        end
        local pad = (maxY - minY) * 0.05
        if pad == 0 then pad = 1 end
        minY = minY - pad; maxY = maxY + pad
    end
    local rangeY = maxY - minY
    if rangeY == 0 then rangeY = 1 end

    local function mapY(v)
        local py = ph - 1 - math.floor((v - minY) / rangeY * (ph - 1))
        if py < 0 then py = 0 end
        if py >= ph then py = ph - 1 end
        return py
    end

    if tOpts.showGrid ~= false then
        local gridC = tOpts.gridColor or 0x222244
        for i = 1, 3 do
            cv:hline(math.floor(ph * i / 4), 0, pw - 1, gridC)
        end
    end

    local nStart = math.max(1, nData - pw + 1)
    local nVis = nData - nStart + 1

    if tOpts.filled then
        local fillC = tOpts.fillColor or color
        for i = 0, nVis - 1 do
            local v = _dGet(tData, nStart + i)
            local py = mapY(v)
            if py < ph - 1 then cv:vline(i, py + 1, ph - 1, fillC) end
        end
    end

    if nVis >= 2 then
        local px0, py0 = 0, mapY(_dGet(tData, nStart))
        for i = 1, nVis - 1 do
            local px1 = i
            local py1 = mapY(_dGet(tData, nStart + i))
            cv:line(px0, py0, px1, py1, color)
            px0 = px1; py0 = py1
        end
    elseif nVis == 1 then
        cv:pixel(0, mapY(_dGet(tData, nStart)), color)
    end

    cv:flush()
end

-- =============================================
-- MULTI-LINE GRAPH
-- Multiple data series on one canvas.
-- tSeries = {{data={...}, color=0xFF5555, label="CPU"}, ...}
-- =============================================

function XE._M:multiLineGraph(sId, x, y, w, h, tSeries, tOpts)
    if self._suspended then return end
    tOpts = tOpts or {}

    local cv = self:canvas(sId, x, y, w, h, tOpts.bgColor or self._baseBg)
    cv:clear()

    if #tSeries == 0 then cv:flush(); return end

    local pw, ph = cv._pixW, cv._pixH

    local minY = tOpts.minY
    local maxY = tOpts.maxY
    if not minY or not maxY then
        minY = math.huge; maxY = -math.huge
        for _, s in ipairs(tSeries) do
            local nD = _dLen(s.data)
            for i = 1, nD do
                local v = _dGet(s.data, i)
                if v < minY then minY = v end
                if v > maxY then maxY = v end
            end
        end
        local pad = (maxY - minY) * 0.05
        if pad == 0 then pad = 1 end
        minY = minY - pad; maxY = maxY + pad
    end
    local rangeY = maxY - minY
    if rangeY == 0 then rangeY = 1 end

    local function mapY(v)
        local py = ph - 1 - math.floor((v - minY) / rangeY * (ph - 1))
        if py < 0 then py = 0 end
        if py >= ph then py = ph - 1 end
        return py
    end

    if tOpts.showGrid ~= false then
        local gridC = tOpts.gridColor or 0x222244
        for i = 1, 3 do
            cv:hline(math.floor(ph * i / 4), 0, pw - 1, gridC)
        end
    end

    for _, s in ipairs(tSeries) do
        local tD = s.data
        local nD = _dLen(tD)
        if nD == 0 then goto nextSeries end
        local c = s.color or 0x55FF55
        local nStart = math.max(1, nD - pw + 1)
        local nVis = nD - nStart + 1

        if nVis >= 2 then
            local px0, py0 = 0, mapY(_dGet(tD, nStart))
            for i = 1, nVis - 1 do
                local px1, py1 = i, mapY(_dGet(tD, nStart + i))
                cv:line(px0, py0, px1, py1, c)
                px0 = px1; py0 = py1
            end
        elseif nVis == 1 then
            cv:pixel(0, mapY(_dGet(tD, nStart)), c)
        end
        ::nextSeries::
    end

    cv:flush()
end

-- =============================================
-- BAR CHART
-- tData = {{value=72, color=0xFF5555, label="CPU"}, ...}
-- or simply {72, 45, 90, ...} (auto-colored)
-- =============================================

function XE._M:barChart(sId, x, y, w, h, tData, tOpts)
    if self._suspended then return end
    tOpts = tOpts or {}

    local cv = self:canvas(sId, x, y, w, h, tOpts.bgColor or self._baseBg)
    cv:clear()

    local nBars = #tData
    if nBars == 0 then cv:flush(); return end

    local pw, ph = cv._pixW, cv._pixH
    local spacing = tOpts.spacing or 1
    local barW = tOpts.barWidth
        or math.max(1, math.floor((pw - spacing * (nBars + 1)) / nBars))

    -- Default color cycle
    local tColors = tOpts.colors or {
        0x55FF55, 0xFF5555, 0x5555FF, 0xFFFF55,
        0xFF55FF, 0x55FFFF, 0xFFAA55, 0xAA55FF,
    }

    -- Find max value
    local maxV = 0
    for i = 1, nBars do
        local v = type(tData[i]) == "table" and tData[i].value or tData[i]
        if v > maxV then maxV = v end
    end
    if maxV == 0 then maxV = 1 end

    -- Draw bars
    for i = 1, nBars do
        local entry = tData[i]
        local v = type(entry) == "table" and entry.value or entry
        local c = (type(entry) == "table" and entry.color)
                  or tColors[((i - 1) % #tColors) + 1]

        local barH = math.max(1, math.floor(v / maxV * (ph - 1)))
        local bx = spacing + (i - 1) * (barW + spacing)
        local by = ph - barH

        cv:fillRect(bx, by, barW, barH, c)
    end

    cv:flush()
end

-- =============================================
-- HEAT ROW — single-row colored intensity map
-- Great for timelines, load history, latency heatmaps.
-- tData = {0.1, 0.5, 0.9, ...} (values 0.0 to 1.0)
-- tColorMap = gradient stops or nil (default green→red)
-- =============================================

function XE._M:heatRow(x, y, w, tData, tColorMap)
    if self._suspended then return end

    tColorMap = tColorMap or {
        {0.0, 0x00AA00}, {0.5, 0xAAAA00}, {1.0, 0xAA0000},
    }

    local function lerp(a, b, t) return math.floor(a + (b - a) * t) end

    local function colorAt(v)
        if v <= 0 then return tColorMap[1][2] end
        if v >= 1 then return tColorMap[#tColorMap][2] end
        for i = 2, #tColorMap do
            if v <= tColorMap[i][1] then
                local lo, hi = tColorMap[i-1], tColorMap[i]
                local t = (v - lo[1]) / (hi[1] - lo[1])
                local clo, chi = lo[2], hi[2]
                local r = lerp(math.floor(clo/65536)%256, math.floor(chi/65536)%256, t)
                local g = lerp(math.floor(clo/256)%256, math.floor(chi/256)%256, t)
                local b = lerp(clo%256, chi%256, t)
                return r*65536 + g*256 + b
            end
        end
        return tColorMap[#tColorMap][2]
    end

    local nData = _dLen(tData)
    local nStart = math.max(1, nData - w + 1)
    local nLeading = w - (nData - nStart + 1)

    local dCh, dFg, dBg = self._dCh, self._dFg, self._dBg
    local rCh = dCh[y]
    local rFg, rBg
    if rCh then rFg = dFg[y]; rBg = dBg[y]
    else
        rCh = {}; rFg = {}; rBg = {}
        dCh[y] = rCh; dFg[y] = rFg; dBg[y] = rBg
    end

    local col = x
    for _ = 1, nLeading do
        if col >= 1 and col <= self.W then
            rCh[col] = _SPACE_BYTE
            rFg[col] = self._baseFg; rBg[col] = self._baseBg
        end
        col = col + 1
    end
    for i = nStart, nData do
        if col > x + w - 1 or col > self.W then break end
        if col >= 1 then
            local c = colorAt(_dGet(tData, i))
            rCh[col] = _FULL_BLOCK; rFg[col] = c; rBg[col] = c
        end
        col = col + 1
    end

    if not self._dtyR[y] then
        self._dtyR[y] = true; self._nDty = self._nDty + 1
    end
end

-- =============================================
-- MODAL SYSTEM
--
-- Modals are stacked. Only the topmost receives input.
-- Backdrop covers the full screen (solid or dimmed).
-- All rendering goes through the delta buffer — the
-- diff engine handles GPU efficiency automatically.
--
-- Performance (80×25 screen):
--   Frame 1 (open):  ~2000 backdrop cells + modal content
--                     → diff emits all as changed → ~30 batch entries
--   Frame 2+ (steady): backdrop unchanged (diff = 0 GPU calls),
--                       only modal content changes emit
--   Close:            app content overwrites backdrop naturally,
--                     diff emits the differences
--
-- Backdrop modes:
--   "solid"  — fill with dark color (O(W*H) writes, O(0) after frame 1)
--   "dim"    — snapshot front buffer, darken each cell (O(W*H) + 48KB RAM)
--   "none"   — no backdrop (transparent, app content visible)
-- =============================================

local function _dimColor(c, factor)
    factor = factor or 3
    local r = math.floor(math.floor(c / 65536) % 256 / factor)
    local g = math.floor(math.floor(c / 256) % 256 / factor)
    local b = math.floor(c % 256 / factor)
    return r * 65536 + g * 256 + b
end

function XE._M:openModal(sId, tOpts)
    tOpts = tOpts or {}
    if self._modals[sId] then return false, "already open" end

    local nW = tOpts.w or tOpts.width  or 40
    local nH = tOpts.h or tOpts.height or 10
    local nX = tOpts.x or math.floor((self.W - nW) / 2) + 1
    local nY = tOpts.y or math.floor((self.H - nH) / 2) + 1

    local sBackdrop = tOpts.backdrop or "solid"
    local nBdColor  = tOpts.backdropColor or 0x080810
    local nBdFg     = tOpts.backdropFg or 0x222233

    -- Save snapshot for "dim" mode (before any modal content is drawn)
    local tSnap = nil
    if sBackdrop == "dim" and self._bShadow then
        tSnap = {ch = {}, fg = {}, bg = {}}
        for y = 1, self.H do
            local sCh, sFg, sBg = {}, {}, {}
            local fc, ff, fb = self._fCh[y], self._fFg[y], self._fBg[y]
            for x = 1, self.W do
                sCh[x] = fc[x]; sFg[x] = ff[x]; sBg[x] = fb[x]
            end
            tSnap.ch[y] = sCh; tSnap.fg[y] = sFg; tSnap.bg[y] = sBg
        end
    end

    local tModal = {
        id       = sId,
        x        = nX,
        y        = nY,
        w        = nW,
        h        = nH,
        title    = tOpts.title,
        backdrop = sBackdrop,
        bdColor  = nBdColor,
        bdFg     = nBdFg,
        bdDimFactor = tOpts.dimFactor or 3,
        noEsc    = tOpts.noEsc or false,
        result   = nil,
        closed   = false,
        -- Per-modal widget focus (saved when not topmost)
        savedFocIdx = nil,
        savedFocId  = nil,
        -- Border colors
        borderFg = tOpts.borderFg or (self._theme and self._theme.border) or 0x5555AA,
        titleFg  = tOpts.titleFg  or (self._theme and self._theme.title)  or 0x55FFFF,
        bodyFg   = tOpts.bodyFg   or (self._theme and self._theme.fg)     or 0xFFFFFF,
        bodyBg   = tOpts.bodyBg   or (self._theme and self._theme.bg)     or 0x111122,
    }

    self._modals[sId] = tModal
    self._modalSnapshots[sId] = tSnap

    -- Push onto stack
    self._modalStack[#self._modalStack + 1] = sId
    self._topModal = sId

    return true
end

function XE._M:beginModal(sId)
    local tM = self._modals[sId]
    if not tM then return false end
    if tM.closed then
        -- Modal was closed last frame — clean up this frame
        self:_removeModal(sId)
        return false
    end

    local mx, my, mw, mh = tM.x, tM.y, tM.w, tM.h

    -- ---- Draw backdrop (only for topmost modal in stack) ----
    if sId == self._modalStack[1] then
        -- First modal in stack → draw backdrop over entire screen
        local sBd = tM.backdrop
        if sBd == "solid" then
            self:fill(1, 1, self.W, self.H, " ", tM.bdFg, tM.bdColor)
        elseif sBd == "dim" then
            local tSnap = self._modalSnapshots[sId]
            if tSnap and self._bShadow then
                local dCh = self._dCh
                local dFg = self._dFg
                local dBg = self._dBg
                local dtyR = self._dtyR
                local nFac = tM.bdDimFactor
                for y = 1, self.H do
                    local rCh = dCh[y]
                    local rFg, rBg
                    if rCh then rFg = dFg[y]; rBg = dBg[y]
                    else
                        rCh = {}; rFg = {}; rBg = {}
                        dCh[y] = rCh; dFg[y] = rFg; dBg[y] = rBg
                    end
                    local sCh = tSnap.ch[y]
                    local sFg = tSnap.fg[y]
                    local sBg = tSnap.bg[y]
                    for x = 1, self.W do
                        rCh[x] = sCh[x]
                        rFg[x] = _dimColor(sFg[x], nFac)
                        rBg[x] = _dimColor(sBg[x], nFac)
                    end
                    if not dtyR[y] then
                        dtyR[y] = true
                        self._nDty = self._nDty + 1
                    end
                end
            else
                -- Fallback to solid if no snapshot
                self:fill(1, 1, self.W, self.H, " ", tM.bdFg, tM.bdColor)
            end
        end
        -- "none" = skip backdrop
    end

    -- ---- Draw modal box ----
    self:fill(mx, my, mw, mh, " ", tM.bodyFg, tM.bodyBg)

    -- Border
    local bfg = tM.borderFg
    local bbg = tM.bodyBg
    local hor = "+" .. string.rep("-", mw - 2) .. "+"
    self:text(mx, my,          hor, bfg, bbg)
    self:text(mx, my + mh - 1, hor, bfg, bbg)
    for ry = my + 1, my + mh - 2 do
        self:text(mx,          ry, "|", bfg, bbg)
        self:text(mx + mw - 1, ry, "|", bfg, bbg)
    end

    -- Title
    if tM.title and #tM.title > 0 then
        local sT = " " .. tM.title .. " "
        local tx = mx + math.max(1, math.floor((mw - #sT) / 2))
        self:text(tx, my, sT, tM.titleFg, bbg)
    end

    -- ---- Enable modal widget registration ----
    self._insideModal = true

    -- Push clip to modal content area
    self:pushClip(mx + 1, my + 1, mw - 2, mh - 2)

    -- Return content area coordinates for caller convenience
    return true, mx + 2, my + 1, mw - 4, mh - 2
end

function XE._M:endModal()
    self:popClip()
    self._insideModal = false
end

function XE._M:closeModal(vResult)
    local sId = self._topModal
    if not sId then return false end
    local tM = self._modals[sId]
    if not tM then return false end
    tM.closed = true
    tM.result = vResult
    return true
end

function XE._M:closeModalById(sId, vResult)
    local tM = self._modals[sId]
    if not tM then return false end
    tM.closed = true
    tM.result = vResult
    return true
end

function XE._M:modalResult(sId)
    local tM = self._modals[sId]
    if not tM then return nil end
    if not tM.closed then return nil end
    local r = tM.result
    -- Auto-cleanup on result retrieval
    self:_removeModal(sId)
    return r
end

function XE._M:hasModal()
    return self._topModal ~= nil
end

function XE._M:topModalId()
    return self._topModal
end

function XE._M:_removeModal(sId)
    self._modals[sId] = nil
    self._modalSnapshots[sId] = nil
    -- Remove from stack
    local tNew = {}
    for _, id in ipairs(self._modalStack) do
        if id ~= sId then tNew[#tNew + 1] = id end
    end
    self._modalStack = tNew
    self._topModal = tNew[#tNew]  -- nil if empty
    -- Reset focus to let app widgets take over
    if not self._topModal then
        self._focIdx = 0
        self._focId = nil
    end
end

-- Shorthand: get topmost modal's content coords
function XE._M:modalArea()
    local sId = self._topModal
    if not sId then return 1, 1, self.W, self.H end
    local tM = self._modals[sId]
    return tM.x + 2, tM.y + 1, tM.w - 4, tM.h - 2
end

-- =============================================
-- PRE-BUILT MODALS
-- IMGUI-style: call each frame, they manage their
-- own state and return results when done.
-- =============================================

-- Alert: single message + OK button.
-- Returns true when dismissed.
function XE._M:alert(sId, sTitle, sMessage, sButton)
    sButton = sButton or "OK"
    local nMW = math.max(#sTitle + 6, #sMessage + 6, #sButton + 10, 24)
    local nMH = 7

    if not self._modals[sId] then
        self:openModal(sId, {title = sTitle, w = nMW, h = nMH, backdrop = "solid"})
    end

    local bVis, cx, cy, cw, ch = self:beginModal(sId)
    if not bVis then
        return self:modalResult(sId) ~= nil
    end

    local tM = self._modals[sId]
    local mx = tM.x

    -- Message (centered)
    local msgX = mx + math.max(2, math.floor((nMW - #sMessage) / 2))
    self:text(msgX, cy + 1, sMessage, tM.bodyFg, tM.bodyBg)

    -- OK button (centered)
    local sBtn = " " .. sButton .. " "
    local btnX = mx + math.floor((nMW - #sBtn) / 2)
    if self:button(sId .. "_ok", btnX, cy + ch - 1, sBtn,
        self:c("btn_fg"), self:c("btn_bg"),
        self:c("btn_hfg"), self:c("btn_hbg")) then
        self:closeModal(true)
    end

    self:endModal()

    local r = self:modalResult(sId)
    return r ~= nil
end

-- Confirm: message + Yes/No buttons.
-- Returns true/false/nil (nil = still open).
function XE._M:confirm(sId, sTitle, sMessage, sYes, sNo)
    sYes = sYes or "Yes"
    sNo  = sNo  or "No"
    local nMW = math.max(#sTitle + 6, #sMessage + 6, #sYes + #sNo + 14, 28)
    local nMH = 7

    if not self._modals[sId] then
        self:openModal(sId, {title = sTitle, w = nMW, h = nMH, backdrop = "solid"})
    end

    local bVis, cx, cy, cw, ch = self:beginModal(sId)
    if not bVis then return self:modalResult(sId) end

    local tM = self._modals[sId]
    local mx = tM.x

    local msgX = mx + math.max(2, math.floor((nMW - #sMessage) / 2))
    self:text(msgX, cy + 1, sMessage, tM.bodyFg, tM.bodyBg)

    local sB1 = " " .. sYes .. " "
    local sB2 = " " .. sNo  .. " "
    local nBtnW = #sB1 + #sB2 + 2
    local btnX = mx + math.floor((nMW - nBtnW) / 2)

    if self:button(sId .. "_yes", btnX, cy + ch - 1, sB1,
        self:c("btn_fg"), self:c("btn_bg"),
        self:c("btn_hfg"), self:c("btn_hbg")) then
        self:closeModal(true)
    end
    if self:button(sId .. "_no", btnX + #sB1 + 2, cy + ch - 1, sB2,
        self:c("btn_fg"), self:c("btn_bg"),
        self:c("btn_hfg"), self:c("btn_hbg")) then
        self:closeModal(false)
    end

    self:endModal()
    return self:modalResult(sId)
end

-- Prompt: text input + OK/Cancel.
-- Returns string (confirmed), false (cancelled), or nil (still open).
function XE._M:prompt(sId, sTitle, sLabel, sDefault)
    local nMW = math.max(#sTitle + 6, #(sLabel or "Input:") + 10, 36)
    local nMH = 8

    if not self._modals[sId] then
        self:openModal(sId, {title = sTitle, w = nMW, h = nMH, backdrop = "solid"})
        -- Seed tracked value — textInput will use this, NOT sDefault
        self._modals[sId]._promptVal = sDefault or ""
    end

    local bVis, cx, cy, cw, ch = self:beginModal(sId)
    if not bVis then return self:modalResult(sId) end

    local tM = self._modals[sId]
    local mx = tM.x

    self:text(mx + 2, cy + 1, sLabel or "Input:", tM.bodyFg, tM.bodyBg)

    local nIW = nMW - 4
    -- Pass tracked value (updated each frame), NOT the original default
    local sVal, bChanged, bSubmit = self:textInput(
        sId .. "_input", mx + 2, cy + 2, nIW, tM._promptVal)

    -- Track changes so next frame passes the CURRENT value
    if bChanged then tM._promptVal = sVal end
    if bSubmit then self:closeModal(sVal) end

    local sB1 = " OK "
    local sB2 = " Cancel "
    local nBtnW = #sB1 + #sB2 + 2
    local btnX = mx + math.floor((nMW - nBtnW) / 2)

    if self:button(sId .. "_ok", btnX, cy + ch - 1, sB1,
        self:c("btn_fg"), self:c("btn_bg"),
        self:c("btn_hfg"), self:c("btn_hbg")) then
        self:closeModal(sVal)
    end
    if self:button(sId .. "_cancel", btnX + #sB1 + 2, cy + ch - 1, sB2,
        self:c("btn_fg"), self:c("btn_bg"),
        self:c("btn_hfg"), self:c("btn_hbg")) then
        self:closeModal(false)
    end

    self:endModal()
    return self:modalResult(sId)
end

-- Select: list of options + OK/Cancel.
-- Returns selected index (1-based), false (cancelled), or nil (still open).
function XE._M:selectModal(sId, sTitle, tOptions, nDefaultIdx)
    local nMaxLabel = 0
    for _, s in ipairs(tOptions) do
        if #s > nMaxLabel then nMaxLabel = #s end
    end
    local nMW = math.max(#sTitle + 6, nMaxLabel + 8, 24)
    local nVisItems = math.min(#tOptions, 8)
    local nMH = nVisItems + 5

    if not self._modals[sId] then
        self:openModal(sId, {title = sTitle, w = nMW, h = nMH, backdrop = "solid"})
        self._scrollState[sId .. "_list"] = {off = 0, sel = nDefaultIdx or 1}
    end

    local bVis, cx, cy, cw, ch = self:beginModal(sId)
    if not bVis then return self:modalResult(sId) end

    local tM = self._modals[sId]
    local mx = tM.x

    -- Scrollable option list
    local nListH = ch - 2
    local first, last, sel, scW, bAct = self:beginScroll(
        sId .. "_list", mx + 2, cy + 1, nMW - 4, nListH, #tOptions)

    for i = first, last do
        local ry = cy + 1 + (i - first)
        local bSel = (i == sel)
        self:textPad(mx + 2, ry, scW,
            " " .. tOptions[i],
            bSel and self:c("sel_fg") or tM.bodyFg,
            bSel and self:c("sel_bg") or tM.bodyBg)
    end
    self:endScroll()

    -- Enter on selection
    if bAct then self:closeModal(sel) end

    -- OK button
    local sBtn = " OK "
    local btnX = mx + math.floor((nMW - #sBtn) / 2)
    if self:button(sId .. "_ok", btnX, cy + ch - 1, sBtn,
        self:c("btn_fg"), self:c("btn_bg"),
        self:c("btn_hfg"), self:c("btn_hbg")) then
        self:closeModal(sel)
    end

    self:endModal()
    return self:modalResult(sId)
end

-- =============================================
-- TOAST NOTIFICATIONS
-- Auto-dismissing messages at screen edge.
-- Zero ongoing cost: expired toasts are removed,
-- their cells revert to app content via diff.
-- =============================================

function XE._M:toast(sMessage, nDurationSec, nFg, nBg)
    nDurationSec = nDurationSec or 3.0
    nFg = nFg or 0xFFFFFF
    nBg = nBg or 0x333355

    -- Get current time (safe access through sandbox chain)
    local nNow = 0
    pcall(function() nNow = computer.uptime() end)

    local nW = #sMessage + 4
    if nW > self.W - 2 then nW = self.W - 2 end

    local tNew = {
        msg      = sMessage,
        fg       = nFg,
        bg       = nBg,
        w        = nW,
        deadline = nNow + nDurationSec,
    }

    -- Push to stack (newest last)
    local t = self._toasts
    t[#t + 1] = tNew

    -- Trim to max
    while #t > self._toastMax do table.remove(t, 1) end
end

function XE._M:_renderToasts()
    local t = self._toasts
    if #t == 0 then return end

    local nNow = 0
    pcall(function() nNow = computer.uptime() end)

    -- Remove expired (iterate backwards for safe removal)
    for i = #t, 1, -1 do
        if t[i].deadline <= nNow then table.remove(t, i) end
    end
    if #t == 0 then return end

    local W = self.W
    for i, toast in ipairs(t) do
        local nTY
        if self._toastPos == "br" then
            nTY = self.H - 1 - (#t - i)
        else
            nTY = 2 + (i - 1)
        end
        if nTY < 1 or nTY > self.H then goto nextToast end

        local nTX = W - toast.w + 1
        if nTX < 1 then nTX = 1 end

        self:fill(nTX, nTY, toast.w, 1, " ", toast.fg, toast.bg)

        local sDisp = toast.msg
        if #sDisp > toast.w - 4 then sDisp = sDisp:sub(1, toast.w - 7) .. "..." end
        self:text(nTX + 2, nTY, sDisp, toast.fg, toast.bg)

        local nRem = toast.deadline - nNow
        if nRem < 1.0 then
            self:text(nTX, nTY, "*", 0xFF5555, toast.bg)
        end

        ::nextToast::
    end
end

-- Convenience wrappers
function XE._M:toastSuccess(s, n) self:toast(s, n or 2.5, 0xFFFFFF, 0x005500) end
function XE._M:toastError(s, n)   self:toast(s, n or 4.0, 0xFFFFFF, 0x880000) end
function XE._M:toastWarn(s, n)    self:toast(s, n or 3.0, 0x000000, 0xAAAA00) end
function XE._M:toastInfo(s, n)    self:toast(s, n or 2.0, 0xFFFFFF, 0x003366) end

-- =============================================
-- DROPDOWN POPUP
-- Opens below trigger position, list of options.
-- Arrow keys navigate, Enter selects, Esc cancels.
-- Returns: selectedIndex, or false, or nil (still open).
-- =============================================

function XE._M:dropdown(sId, x, y, w, tOptions, nCurrentIdx)
    nCurrentIdx = nCurrentIdx or 1

    local dd = self._dropdowns[sId]
    if not dd then
        dd = {open = false, sel = nCurrentIdx, off = 0}
        self._dropdowns[sId] = dd
    end

    -- ---- Trigger ----
    local sCur = tOptions[nCurrentIdx] or ""
    if #sCur > w - 5 then sCur = sCur:sub(1, w - 8) .. "..." end
    local nPad = math.max(0, w - #sCur - 5)
    local sDisp = " " .. sCur .. string.rep(" ", nPad) .. " v "

    if dd.open then
        self:text(x, y, sDisp, self:c("input_afg"), self:c("input_abg"))
    else
        if self:button(sId .. "_t", x, y, sDisp,
            self:c("input_fg"), self:c("input_bg"),
            self:c("input_afg"), self:c("input_abg")) then
            dd.open = true; dd.sel = nCurrentIdx; dd.off = 0
        end
    end

    if not dd.open then return nil end

    -- ---- Popup geometry ----
    local nVis = math.min(#tOptions, 6)
    local popY = y + 1
    if popY + nVis > self.H then popY = y - nVis end
    if popY < 1 then popY = 1 end

    -- ---- Mouse click on popup item or outside ----
    if self._mouseClicked then
        local mx, my = self._mouseX, self._mouseY
        if mx and mx >= x and mx < x + w and my >= popY and my < popY + nVis then
            -- Click inside popup → select item
            local nItem = dd.off + (my - popY) + 1
            if nItem >= 1 and nItem <= #tOptions then
                dd.open = false; self._mouseClicked = false
                return nItem
            end
        elseif mx and mx >= x and mx < x + w and my == y then
            -- Click on trigger → toggle close
            dd.open = false; self._mouseClicked = false
            return nil
        else
            -- Click outside → close
            dd.open = false; self._mouseClicked = false
            return nil
        end
    end

    -- ---- Scroll wheel inside popup ----
    if self._scrollDelta then
        local sx, sy = self._scrollX, self._scrollY
        if sx and sx >= x and sx < x + w and sy >= popY and sy < popY + nVis then
            if self._scrollDelta < 0 then
                dd.sel = math.max(1, dd.sel - 1)
            else
                dd.sel = math.min(#tOptions, dd.sel + 1)
            end
            self._scrollDelta = nil
        end
    end

    -- ---- Keyboard navigation ----
    local k = self._key
    if k then
        if k == "\27[A" then
            dd.sel = math.max(1, dd.sel - 1); self._key = nil
        elseif k == "\27[B" then
            dd.sel = math.min(#tOptions, dd.sel + 1); self._key = nil
        elseif k == "\n" then
            dd.open = false; self._key = nil; self._act = false
            return dd.sel
        elseif k == "\t" or k == "\27[Z" then
            dd.open = false; self._key = nil
            return nil
        end
    end

    -- ---- Scroll offset ----
    if dd.sel < dd.off + 1 then dd.off = dd.sel - 1 end
    if dd.sel > dd.off + nVis then dd.off = dd.sel - nVis end
    if dd.off < 0 then dd.off = 0 end

    -- ---- Defer popup rendering to endFrame (always on top) ----
    self._pendingDropdown = {
        x = x, y = popY, w = w,
        options = tOptions,
        sel = dd.sel, off = dd.off,
        nVis = nVis,
    }

    return nil
end

-- =============================================
-- COMMAND PALETTE
-- Centered fuzzy-search popup with text input + filtered list.
-- tCommands = {{id="quit", label="Quit App", shortcut="Q"}, ...}
-- Returns: command id string, false (cancelled), or nil (still open).
-- =============================================

function XE._M:commandPalette(sId, tCommands)
    local nMW = math.min(50, self.W - 4)
    local nMH = math.min(14, self.H - 4)
    local nMX = math.floor((self.W - nMW) / 2) + 1
    local nMY = 3  -- near top, like VS Code

    if not self._modals[sId] then
        self:openModal(sId, {
            x = nMX, y = nMY, w = nMW, h = nMH,
            title = "Commands", backdrop = "solid",
        })
        self._palette = {filter = "", commands = tCommands, filtered = tCommands}
    end

    local bVis, cx, cy, cw, ch = self:beginModal(sId)
    if not bVis then
        local r = self:modalResult(sId)
        self._palette = nil
        return r
    end

    local tM = self._modals[sId]
    local mx, my = tM.x, tM.y
    local pal = self._palette

    -- Search input
    local sFilter, bChanged, bSubmit = self:textInput(
        sId .. "_search", mx + 2, cy, nMW - 4, pal.filter)

    if bChanged then
        pal.filter = sFilter
        -- Fuzzy filter: case-insensitive substring match
        local sLow = sFilter:lower()
        pal.filtered = {}
        if #sLow == 0 then
            pal.filtered = pal.commands
        else
            for _, cmd in ipairs(pal.commands) do
                if cmd.label:lower():find(sLow, 1, true)
                   or cmd.id:lower():find(sLow, 1, true) then
                    pal.filtered[#pal.filtered + 1] = cmd
                end
            end
        end
        -- Reset scroll position
        self._scrollState[sId .. "_list"] = {off = 0, sel = 1}
    end

    -- Separator
    self:text(mx + 1, cy + 1,
        string.rep("-", nMW - 2), self:c("border"), tM.bodyBg)

    -- Filtered command list
    local tF = pal.filtered
    local nListH = ch - 3
    if nListH < 1 then nListH = 1 end

    local first, last, sel, scW, bAct = self:beginScroll(
        sId .. "_list", mx + 2, cy + 2, nMW - 4, nListH, #tF)

    for i = first, last do
        local ry = cy + 2 + (i - first)
        local bSel = (i == sel)
        local cmd = tF[i]
        if cmd then
            local sLabel = cmd.label or cmd.id
            local sShort = cmd.shortcut or ""
            local nLabelW = scW - #sShort - 1
            if #sLabel > nLabelW then sLabel = sLabel:sub(1, nLabelW - 2) .. ".." end

            local sFg = bSel and self:c("sel_fg") or self:c("fg")
            local sBg = bSel and self:c("sel_bg") or tM.bodyBg
            self:textPad(mx + 2, ry, nLabelW, sLabel, sFg, sBg)
            if #sShort > 0 then
                self:text(mx + 2 + nLabelW, ry, sShort, self:c("dim"), sBg)
            end
        end
    end
    self:endScroll()

    -- Submit on Enter (from input or list)
    if (bSubmit or bAct) and #tF > 0 then
        local cmd = tF[sel]
        if cmd then self:closeModal(cmd.id) end
    end

    -- Item count
    self:textf(mx + 2, cy + ch - 1, self:c("dim"), tM.bodyBg,
        "%d/%d", #tF, #pal.commands)

    self:endModal()

    local r = self:modalResult(sId)
    if r ~= nil then self._palette = nil end
    return r
end

return XE
