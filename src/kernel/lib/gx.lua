-- /lib/gx.lua
-- Graphics Extension API — userspace library
-- local gx = require("gx")
-- local inst = gx.createInstance({ extensions = {"GX_AX_surface", ...} })

local GX = {}

-- ═══════════════════════════════════════════
-- EXTENSION REGISTRY
-- ═══════════════════════════════════════════

local g_tReg = {}

function GX.registerExtension(sName, tDef)
    g_tReg[sName] = tDef
end

-- ═══════════════════════════════════════════
-- INSTANCE
-- ═══════════════════════════════════════════

local IM = {}  -- instance methods metatable

function GX.createInstance(tOpts)
    tOpts = tOpts or {}
    local inst = {
        _tLoaded    = {},
        _nDefaultGpu = tOpts.nGpu or 1,
        _tOwned     = {},  -- surfaces this instance created
    }
    setmetatable(inst, { __index = IM })

    local tExts = tOpts.extensions or { "GX_AX_surface", "GX_AX_input", "GX_AX_present" }
    for _, sExt in ipairs(tExts) do
        inst:loadExtension(sExt)
    end
    return inst
end

function IM:loadExtension(sName)
    if self._tLoaded[sName] then return true end

    local tDef = g_tReg[sName]
    if not tDef then
        error("GX: unknown extension: " .. sName)
    end

    -- Ring check
    if tDef.nMinRing then
        local nRing = syscall("process_get_ring") or 3
        if nRing > tDef.nMinRing then
            error(string.format("GX: %s requires Ring %d, caller is %d",
                sName, tDef.nMinRing, nRing))
        end
    end

    -- Dependencies
    for _, sDep in ipairs(tDef.tDeps or {}) do
        self:loadExtension(sDep)
    end

    tDef.fLoad(self)
    self._tLoaded[sName] = true
    return true
end

function IM:hasExtension(sName)
    return self._tLoaded[sName] == true
end

function IM:destroy()
    for h in pairs(self._tOwned) do
        pcall(syscall, "gdi_destroy_surface", h)
    end
    self._tOwned = {}
end

-- ═══════════════════════════════════════════
-- GX_AX_surface — core surface ops
-- ═══════════════════════════════════════════

GX.registerExtension("GX_AX_surface", {
    tDeps = {},
    fLoad = function(self)
        function self:createSurface(nW, nH, tOpts)
            tOpts = tOpts or {}
            tOpts.nGpuTarget = tOpts.nGpuTarget or self._nDefaultGpu
            local h = syscall("gdi_create_surface", nW, nH, tOpts)
            if h then self._tOwned[h] = true end
            return h
        end
        function self:destroySurface(h)
            self._tOwned[h] = nil
            return syscall("gdi_destroy_surface", h)
        end
        function self:resizeSurface(h, nW, nH)
            return syscall("gdi_resize_surface", h, nW, nH)
        end
        function self:set(h, x, y, s, fg, bg)
            return syscall("gdi_surface_set", h, x, y, s, fg, bg)
        end
        function self:fill(h, x, y, w, nh, c, fg, bg)
            return syscall("gdi_surface_fill", h, x, y, w, nh, c, fg, bg)
        end
        function self:scroll(h, n)
            return syscall("gdi_surface_scroll", h, n)
        end
        function self:clear(h, fg, bg)
            return syscall("gdi_surface_clear", h, fg, bg)
        end
        function self:getSize(h)
            return syscall("gdi_surface_get_size", h)
        end
        function self:setVisible(h, b)
            return syscall("gdi_surface_set_visible", h, b)
        end
        function self:setPosition(h, x, y)
            return syscall("gdi_surface_set_position", h, x, y)
        end
    end,
})

-- ═══════════════════════════════════════════
-- GX_AX_input — keyboard I/O
-- ═══════════════════════════════════════════

GX.registerExtension("GX_AX_input", {
    tDeps = {},
    fLoad = function(self)
        function self:popInput(h)
            return syscall("gdi_pop_input", h)
        end
        function self:pushInput(h, tEvt)
            return syscall("gdi_push_input", h, tEvt)
        end
        function self:waitInput(h)
            -- Blocking read: yield until input arrives
            while true do
                local evt = syscall("gdi_pop_input", h)
                if evt then return evt end
                coroutine.yield()
            end
        end
        function self:setFocus(h)
            return syscall("gdi_set_focus", h)
        end
        function self:getFocus()
            return syscall("gdi_get_focus")
        end
        function self:inputReady(h)
            return (syscall("gdi_input_queue_size", h) or 0) > 0
        end
    end,
})

-- ═══════════════════════════════════════════
-- GX_AX_present — compositor trigger
-- ═══════════════════════════════════════════

GX.registerExtension("GX_AX_present", {
    tDeps = {},
    fLoad = function(self)
        function self:present()
            return syscall("gdi_composite")
        end
    end,
})

-- ═══════════════════════════════════════════
-- GX_AX_query — enumeration
-- ═══════════════════════════════════════════

GX.registerExtension("GX_AX_query", {
    tDeps = {},
    fLoad = function(self)
        function self:getGpuCount()
            return syscall("gdi_get_gpu_count")
        end
        function self:getGpuInfo(n)
            return syscall("gdi_get_gpu_info", n)
        end
        function self:getSurfaceList()
            return syscall("gdi_get_surface_list")
        end
    end,
})

-- ═══════════════════════════════════════════
-- GX_EXT_batch — command buffer
-- ═══════════════════════════════════════════

GX.registerExtension("GX_EXT_batch", {
    tDeps = {"GX_AX_surface"},
    fLoad = function(self)
        function self:beginBatch(h)
            local B = { _h = h, _ops = {} }
            function B:set(x, y, s, fg, bg)
                self._ops[#self._ops + 1] = {"set", x, y, s, fg, bg}
                return self
            end
            function B:fill(x, y, w, nh, c, fg, bg)
                self._ops[#self._ops + 1] = {"fill", x, y, w, nh, c, fg, bg}
                return self
            end
            function B:scroll(n)
                self._ops[#self._ops + 1] = {"scroll", n}
                return self
            end
            function B:clear(fg, bg)
                self._ops[#self._ops + 1] = {"clear", fg, bg}
                return self
            end
            function B:submit()
                return syscall("gdi_batch_submit", self._h, self._ops)
            end
            return B
        end
    end,
})

-- ═══════════════════════════════════════════
-- GX_EXT_text_buffer — terminal-like output
-- ═══════════════════════════════════════════

GX.registerExtension("GX_EXT_text_buffer", {
    tDeps = {"GX_AX_surface"},
    fLoad = function(inst)
        function inst:createTextBuffer(h, nMaxScrollback)
            local nW, nH = syscall("gdi_surface_get_size", h)
            if not nW then error("GX: bad surface for text_buffer") end

            local tb = {
                _h   = h,
                _nW  = nW,
                _nH  = nH,
                _cx  = 1,
                _cy  = 1,
                _fg  = 0xFFFFFF,
                _bg  = 0x000000,
            }

            function tb:write(sText)
                for i = 1, #sText do
                    local c = sText:sub(i, i)
                    if c == "\n" then
                        self:_newline()
                    elseif c == "\r" then
                        self._cx = 1
                    elseif c == "\t" then
                        local nSp = 4 - ((self._cx - 1) % 4)
                        for _ = 1, nSp do self:_putChar(" ") end
                    elseif c == "\8" then -- backspace
                        if self._cx > 1 then
                            self._cx = self._cx - 1
                            syscall("gdi_surface_set", self._h,
                                self._cx, self._cy, " ", self._fg, self._bg)
                        end
                    else
                        self:_putChar(c)
                    end
                end
            end

            function tb:_putChar(c)
                if self._cx > self._nW then self:_newline() end
                syscall("gdi_surface_set", self._h,
                    self._cx, self._cy, c, self._fg, self._bg)
                self._cx = self._cx + 1
            end

            function tb:_newline()
                self._cx = 1
                if self._cy < self._nH then
                    self._cy = self._cy + 1
                else
                    syscall("gdi_surface_scroll", self._h, 1)
                end
            end

            function tb:setColor(fg, bg)
                if fg then self._fg = fg end
                if bg then self._bg = bg end
            end

            function tb:setCursor(x, y)
                self._cx = x; self._cy = y
            end

            function tb:getCursor()
                return self._cx, self._cy
            end

            function tb:clear()
                syscall("gdi_surface_clear", self._h, self._fg, self._bg)
                self._cx = 1; self._cy = 1
            end

            function tb:clearLine(y)
                y = y or self._cy
                syscall("gdi_surface_fill", self._h,
                    1, y, self._nW, 1, " ", self._fg, self._bg)
            end

            function tb:getSize() return self._nW, self._nH end

            return tb
        end
    end,
})

-- ═══════════════════════════════════════════
-- GX_EXT_readline — line editing with history
-- ═══════════════════════════════════════════

GX.registerExtension("GX_EXT_readline", {
    tDeps = {"GX_EXT_text_buffer", "GX_AX_input"},
    fLoad = function(inst)
        function inst:createReadline(h, tb, tOpts)
            tOpts = tOpts or {}
            local rl = {
                _h       = h,
                _tb      = tb,
                _inst    = inst,
                _tHist   = {},
                _nMaxH   = tOpts.nMaxHistory or 100,
            }

            function rl:read(sPrompt)
                sPrompt = sPrompt or ""
                local tb = self._tb
                local inst = self._inst

                tb:write(sPrompt)
                local nPromptX = tb._cx

                local sBuf  = ""
                local nCur  = 0  -- cursor offset into sBuf
                local nHIdx = #self._tHist + 1
                local sSaved = ""

                local function redraw()
                    -- Clear from prompt to end of line
                    syscall("gdi_surface_fill", self._h,
                        nPromptX, tb._cy, tb._nW - nPromptX + 1, 1,
                        " ", tb._fg, tb._bg)
                    -- Draw current buffer
                    syscall("gdi_surface_set", self._h,
                        nPromptX, tb._cy, sBuf, tb._fg, tb._bg)
                    -- Position cursor
                    tb._cx = nPromptX + nCur
                end

                while true do
                    redraw()
                    syscall("gdi_composite")

                    local evt = inst:waitInput(self._h)
                    if not evt or evt.sType ~= "key_down" then
                        goto continue
                    end

                    local ch  = evt.nChar
                    local code = evt.nCode

                    if ch == 13 then -- Enter
                        tb._cx = nPromptX + #sBuf
                        tb:write("\n")
                        if #sBuf > 0 then
                            self._tHist[#self._tHist + 1] = sBuf
                            if #self._tHist > self._nMaxH then
                                table.remove(self._tHist, 1)
                            end
                        end
                        return sBuf

                    elseif ch == 8 or ch == 127 then -- Backspace
                        if nCur > 0 then
                            sBuf = sBuf:sub(1, nCur - 1) .. sBuf:sub(nCur + 1)
                            nCur = nCur - 1
                        end

                    elseif ch == 0 then -- Special keys (arrows etc)
                        if code == 203 then -- Left
                            if nCur > 0 then nCur = nCur - 1 end
                        elseif code == 205 then -- Right
                            if nCur < #sBuf then nCur = nCur + 1 end
                        elseif code == 199 then -- Home
                            nCur = 0
                        elseif code == 207 then -- End
                            nCur = #sBuf
                        elseif code == 200 then -- Up (history)
                            if nHIdx > 1 then
                                if nHIdx == #self._tHist + 1 then
                                    sSaved = sBuf
                                end
                                nHIdx = nHIdx - 1
                                sBuf = self._tHist[nHIdx]
                                nCur = #sBuf
                            end
                        elseif code == 208 then -- Down (history)
                            if nHIdx <= #self._tHist then
                                nHIdx = nHIdx + 1
                                if nHIdx > #self._tHist then
                                    sBuf = sSaved
                                else
                                    sBuf = self._tHist[nHIdx]
                                end
                                nCur = #sBuf
                            end
                        elseif code == 211 then -- Delete
                            if nCur < #sBuf then
                                sBuf = sBuf:sub(1, nCur) .. sBuf:sub(nCur + 2)
                            end
                        end

                    elseif ch == 3 then -- Ctrl+C
                        tb:write("^C\n")
                        return nil

                    elseif ch == 4 then -- Ctrl+D
                        if #sBuf == 0 then return nil end

                    elseif ch == 21 then -- Ctrl+U (clear line)
                        sBuf = sBuf:sub(nCur + 1)
                        nCur = 0

                    elseif ch == 11 then -- Ctrl+K (kill to end)
                        sBuf = sBuf:sub(1, nCur)

                    elseif ch >= 32 and ch < 127 then -- Printable
                        sBuf = sBuf:sub(1, nCur) .. string.char(ch) .. sBuf:sub(nCur + 1)
                        nCur = nCur + 1
                    end

                    ::continue::
                end
            end

            return rl
        end
    end,
})

-- ═══════════════════════════════════════════
-- GX_EXT_layers — z-order management
-- ═══════════════════════════════════════════

GX.registerExtension("GX_EXT_layers", {
    tDeps = {"GX_AX_surface"},
    fLoad = function(self)
        function self:setZOrder(h, n)
            return syscall("gdi_surface_set_z", h, n)
        end
        function self:bringToFront(h)
            return syscall("gdi_surface_bring_to_front", h)
        end
    end,
})

-- ═══════════════════════════════════════════
-- GX_EXT_double_buffer — swap chain
-- ═══════════════════════════════════════════

GX.registerExtension("GX_EXT_double_buffer", {
    tDeps = {"GX_AX_surface", "GX_AX_present"},
    fLoad = function(self)
        function self:createSwapChain(nW, nH, tOpts)
            tOpts = tOpts or {}
            local hFront = self:createSurface(nW, nH, tOpts)
            local tBack  = {}
            for k, v in pairs(tOpts) do tBack[k] = v end
            tBack.bVisible = false
            local hBack = self:createSurface(nW, nH, tBack)
            return { front = hFront, back = hBack }
        end
        function self:swap(tChain)
            syscall("gdi_surface_set_visible", tChain.back, true)
            syscall("gdi_surface_set_visible", tChain.front, false)
            tChain.front, tChain.back = tChain.back, tChain.front
            return self:present()
        end
    end,
})

-- ═══════════════════════════════════════════
-- GX_SYS_gpu_bind — privileged GPU binding
-- ═══════════════════════════════════════════

GX.registerExtension("GX_SYS_gpu_bind", {
    nMinRing = 1,
    tDeps = {"GX_AX_query"},
    fLoad = function(self)
        function self:bindGpu(nIdx, sScreenAddr)
            return syscall("gdi_bind_gpu", nIdx, sScreenAddr)
        end
    end,
})

-- ═══════════════════════════════════════════
-- GX_SYS_multi_gpu — surface ↔ GPU targeting
-- ═══════════════════════════════════════════

GX.registerExtension("GX_SYS_multi_gpu", {
    nMinRing = 1,
    tDeps = {"GX_AX_surface", "GX_AX_query"},
    fLoad = function(self)
        function self:setSurfaceGpu(h, nIdx)
            return syscall("gdi_surface_set_gpu", h, nIdx)
        end
    end,
})

-- ═══════════════════════════════════════════
-- GX_SYS_compositor_ctl
-- ═══════════════════════════════════════════

GX.registerExtension("GX_SYS_compositor_ctl", {
    nMinRing = 1,
    tDeps = {},
    fLoad = function(self)
        function self:forceRedraw()
            return syscall("gdi_force_redraw")
        end
    end,
})

-- ═══════════════════════════════════════════
-- GX_SYS_direct_access — raw GPU bypass
-- ═══════════════════════════════════════════

GX.registerExtension("GX_SYS_direct_access", {
    nMinRing = 0,
    tDeps = {},
    fLoad = function(self)
        function self:getRawGpu(nIdx)
            return syscall("gdi_get_raw_gpu", nIdx)
        end
    end,
})

return GX