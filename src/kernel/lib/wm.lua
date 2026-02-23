--
-- /lib/wm.lua
-- AxisOS Window Manager — Fast Drag, No Blink
--

local oWm = {}

-- Proper Unicode box-drawing (safe fallback to ASCII)
local _uc = unicode and unicode.char or function(n)
    if n < 0x80 then return string.char(n) end
    if n < 0x800 then
        return string.char(0xC0 + math.floor(n / 64), 0x80 + n % 64)
    end
    return string.char(
        0xE0 + math.floor(n / 4096),
        0x80 + math.floor(n / 64) % 64,
        0x80 + n % 64)
end

local CH_VLINE = _uc(0x2502)  -- │
local CH_HLINE = _uc(0x2500)  -- ─
local CH_CROSS = "X"           -- close button glyph

-- Colors
local C_TITLE_BG  = 0x0D2B52
local C_TITLE_FG  = 0xFFFFFF
local C_CLOSE_FG  = 0xFF5555
local C_BORDER    = 0x3A3A5E
local C_BODY_BG   = 0x0C0C1E
local C_BODY_FG   = 0xCCCCDD

local TITLE_H   = 1
local BORDER_L  = 1
local BORDER_R  = 1
local BORDER_B  = 1

local g_tWindows = {}

local function fDrawDecorations(tW)
    local h = tW.hSurface
    local nTW, nTH = tW.nTotalW, tW.nTotalH

    -- Title bar
    syscall("gdi_surface_fill", h, 1, 1, nTW, TITLE_H, " ",
            C_TITLE_FG, C_TITLE_BG)
    local sT = " " .. (tW.sTitle or "")
    if #sT > nTW - 6 then sT = sT:sub(1, nTW - 9) .. "..." end
    syscall("gdi_surface_set", h, 1, 1, sT, C_TITLE_FG, C_TITLE_BG)

    -- Close button [X]
    syscall("gdi_surface_set", h, nTW - 3, 1, " " .. CH_CROSS .. " ",
            C_CLOSE_FG, C_TITLE_BG)

    -- Left / right borders
    for y = TITLE_H + 1, nTH - BORDER_B do
        syscall("gdi_surface_set", h, 1, y, CH_VLINE,
                C_BORDER, C_BODY_BG)
        syscall("gdi_surface_set", h, nTW, y, CH_VLINE,
                C_BORDER, C_BODY_BG)
    end

    -- Bottom border
    local tBot = {}
    for i = 1, nTW do tBot[i] = CH_HLINE end
    syscall("gdi_surface_set", h, 1, nTH, table.concat(tBot),
            C_BORDER, C_BODY_BG)

    -- Content area clear
    syscall("gdi_surface_fill", h,
        BORDER_L + 1, TITLE_H + 1,
        tW.nContentW, tW.nContentH,
        " ", C_BODY_FG, C_BODY_BG)
end

function oWm.createWindow(sTitle, nCW, nCH, tOpts)
    tOpts = tOpts or {}
    local nTW = nCW + BORDER_L + BORDER_R
    local nTH = nCH + TITLE_H + BORDER_B
    local nSX = tOpts.nX or 5
    local nSY = tOpts.nY or 3

    local hS = syscall("gdi_create_surface", nTW, nTH, {
        bVisible     = true,
        nScreenX     = nSX,
        nScreenY     = nSY,
        nZOrder      = tOpts.nZ or 100,
        sLabel       = sTitle or "Window",
        bDraggable   = true,
        nTitleHeight = TITLE_H,
    })
    if not hS then return nil, "Surface creation failed" end

    local tW = {
        hSurface  = hS,
        sTitle    = sTitle or "Window",
        nTotalW   = nTW,
        nTotalH   = nTH,
        nContentW = nCW,
        nContentH = nCH,
        bClosed   = false,
    }
    g_tWindows[hS] = tW
    fDrawDecorations(tW)
    syscall("gdi_set_focus", hS)
    return hS
end

function oWm.destroyWindow(h)
    g_tWindows[h] = nil
    syscall("gdi_destroy_surface", h)
end

function oWm.set(h, x, y, s, fg, bg)
    local tW = g_tWindows[h]; if not tW then return end
    syscall("gdi_surface_set", h, x + BORDER_L, y + TITLE_H,
            s, fg or C_BODY_FG, bg or C_BODY_BG)
end

function oWm.fill(h, x, y, w, nh, ch, fg, bg)
    local tW = g_tWindows[h]; if not tW then return end
    syscall("gdi_surface_fill", h,
        x + BORDER_L, y + TITLE_H,
        w, nh, ch or " ", fg or C_BODY_FG, bg or C_BODY_BG)
end

function oWm.clear(h, fg, bg)
    local tW = g_tWindows[h]; if not tW then return end
    syscall("gdi_surface_fill", h,
        BORDER_L + 1, TITLE_H + 1,
        tW.nContentW, tW.nContentH,
        " ", fg or C_BODY_FG, bg or C_BODY_BG)
end

function oWm.getContentSize(h)
    local tW = g_tWindows[h]; if not tW then return nil end
    return tW.nContentW, tW.nContentH
end

function oWm.setTitle(h, sTitle)
    local tW = g_tWindows[h]; if not tW then return end
    tW.sTitle = sTitle; fDrawDecorations(tW)
end

function oWm.present()
    syscall("gdi_composite")
end

function oWm.pollEvent(h)
    local tW = g_tWindows[h]
    if not tW then return nil end
    if tW.bClosed then return { sType = "close_requested" } end
    local evt = syscall("gdi_pop_input", h)
    if not evt then return nil end
    if evt.sType == "close_requested" then
        tW.bClosed = true
    end
    if evt.sType == "key_down" and evt.nChar == 23 then
        tW.bClosed = true
        return { sType = "close_requested" }
    end
    return evt
end

function oWm.focus(h)
    syscall("gdi_set_focus", h)
    syscall("gdi_surface_bring_to_front", h)
end

function oWm.isAlive(h)
    local tW = g_tWindows[h]
    return tW ~= nil and not tW.bClosed
end

function oWm.listWindows()
    local t = {}
    for hS, tW in pairs(g_tWindows) do
        t[#t + 1] = { hSurface = hS, sTitle = tW.sTitle }
    end
    return t
end

return oWm