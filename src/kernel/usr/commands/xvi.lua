--
-- /usr/commands/xvi.lua
-- xvi — Memory-Safe Paged Vi for AxisOS
--
-- Only 4 pages (~200 lines) live in RAM at any time.
-- A 10,000-line file uses the same memory as a 200-line file.
-- Evicted dirty pages swap to /tmp/.xvi/ on disk.
-- XE delta rendering: zero flicker, minimal GPU calls.
--

local fs = require("filesystem")
local xe = require("xe")

local HL = nil
pcall(function() HL = require("vi/highlight") end)

local tArgs = env.ARGS or {}

-- =============================================
-- 1. CONSTANTS
-- =============================================

local PAGE_SZ   = 48
local MAX_CACHE  = 4
local MAX_UNDO   = 6
local SWAP_DIR   = "/tmp/.xvi"
local SCROLL_OFF = 3

-- =============================================
-- 2. PAGED BUFFER
-- =============================================

-- Forward declarations
local ensurePage, swapOut, readOrigPage, readSwap
local getLine, setLine, insertLine, deleteLine

local buf = {
    meta    = {},    -- meta[i] = lineCount per page (always in RAM)
    nPages  = 0,
    nTotal  = 0,
    cache   = {},    -- cache[pageNum] = {lines={...}, dirty=false}
    lru     = {},
    nCached = 0,
    origPath = nil,
    sPath    = nil,
    offsets  = {},   -- offsets[pageNum] = {byteStart, byteLen}
    swapped  = {},   -- swapped[pageNum] = true
    modified = false,
    tLang    = nil,
}

local function lruTouch(n)
    local L = buf.lru
    for i = #L, 1, -1 do if L[i] == n then table.remove(L, i); break end end
    L[#L + 1] = n
end
local function lruOldest() return buf.lru[1] end
local function lruRemove(n)
    for i = #buf.lru, 1, -1 do if buf.lru[i] == n then table.remove(buf.lru, i); break end end
end

swapOut = function(nP)
    local pg = buf.cache[nP]; if not pg then return end
    if pg.dirty then
        fs.mkdir("/tmp"); fs.mkdir(SWAP_DIR)
        local h = fs.open(SWAP_DIR .. "/p" .. nP, "w")
        if h then
            for i, s in ipairs(pg.lines) do
                fs.write(h, s); if i < #pg.lines then fs.write(h, "\n") end
            end
            fs.close(h)
            buf.swapped[nP] = true
        end
    end
    pg.lines = nil
    buf.cache[nP] = nil
    buf.nCached = buf.nCached - 1
    lruRemove(nP)
end

readSwap = function(nP)
    local h = fs.open(SWAP_DIR .. "/p" .. nP, "r")
    if not h then return {""} end
    local tC = {}
    while true do local s = fs.read(h, math.huge); if not s then break end; tC[#tC+1] = s end
    fs.close(h)
    local sA = table.concat(tC); tC = nil
    if #sA == 0 then return {""} end
    local t = {}
    for sL in (sA .. "\n"):gmatch("([^\n]*)\n") do t[#t+1] = sL end
    sA = nil
    while #t > (buf.meta[nP] or 1) and #t > 1 and t[#t] == "" do t[#t] = nil end
    if #t == 0 then t[1] = "" end
    return t
end

readOrigPage = function(nP)
    local off = buf.offsets[nP]
    if not off or not buf.origPath then return {""} end
    local h = fs.open(buf.origPath, "r")
    if not h then return {""} end
    local nSkip = off[1]
    while nSkip > 0 do
        local s = fs.read(h, math.min(nSkip, 4096))
        if not s then fs.close(h); return {""} end
        nSkip = nSkip - #s
    end
    local tC = {}; local nRem = off[2]
    while nRem > 0 do
        local s = fs.read(h, math.min(nRem, 4096))
        if not s then break end; tC[#tC+1] = s; nRem = nRem - #s
    end
    fs.close(h)
    local sA = table.concat(tC); tC = nil
    local t = {}
    if #sA == 0 then return {""} end
    for sL in (sA .. "\n"):gmatch("([^\n]*)\n") do t[#t+1] = sL end
    sA = nil
    while #t > (buf.meta[nP] or 1) and #t > 1 and t[#t] == "" do t[#t] = nil end
    if #t == 0 then t[1] = "" end
    return t
end

ensurePage = function(nP)
    if nP < 1 then nP = 1 end
    if buf.cache[nP] then lruTouch(nP); return buf.cache[nP] end
    while buf.nCached >= MAX_CACHE do
        local nE = lruOldest(); if nE then swapOut(nE) else break end
    end
    local tL
    if buf.swapped[nP] then tL = readSwap(nP)
    else tL = readOrigPage(nP) end
    buf.cache[nP] = { lines = tL, dirty = buf.swapped[nP] or false }
    buf.nCached = buf.nCached + 1
    lruTouch(nP)
    return buf.cache[nP]
end

local function lineToPage(nLine)
    local acc = 0
    for i = 1, buf.nPages do
        local c = buf.meta[i] or 0
        if c > 0 and nLine <= acc + c then return i, nLine - acc end
        acc = acc + c
    end
    if buf.nPages == 0 then return 1, 1 end
    return buf.nPages, buf.meta[buf.nPages] or 1
end

getLine = function(nL)
    if nL < 1 or nL > buf.nTotal then return "" end
    local nP, nI = lineToPage(nL)
    return ensurePage(nP).lines[nI] or ""
end

setLine = function(nL, s)
    local nP, nI = lineToPage(nL)
    local pg = ensurePage(nP)
    pg.lines[nI] = s; pg.dirty = true; buf.modified = true
end

insertLine = function(nAfter, s)
    local nP, nI
    if nAfter < 1 then nP = 1; nI = 0
    else nP, nI = lineToPage(math.min(nAfter, buf.nTotal)) end
    local pg = ensurePage(nP)
    table.insert(pg.lines, nI + 1, s)
    buf.meta[nP] = (buf.meta[nP] or 0) + 1
    buf.nTotal = buf.nTotal + 1
    pg.dirty = true; buf.modified = true
end

deleteLine = function(nL)
    if buf.nTotal <= 1 then setLine(1, ""); return end
    local nP, nI = lineToPage(nL)
    local pg = ensurePage(nP)
    table.remove(pg.lines, nI)
    buf.meta[nP] = math.max(0, (buf.meta[nP] or 1) - 1)
    buf.nTotal = buf.nTotal - 1
    pg.dirty = true; buf.modified = true
end

-- =============================================
-- 3. FILE I/O
-- =============================================

local function openFile(sPath)
    if sPath:sub(1,1) ~= "/" then sPath = (env.PWD or "/") .. "/" .. sPath end
    sPath = sPath:gsub("//", "/")
    local h = fs.open(sPath, "r")
    if not h then return false, "Cannot open: " .. sPath end

    buf.origPath = sPath; buf.sPath = sPath
    buf.meta = {}; buf.cache = {}; buf.lru = {}; buf.nCached = 0
    buf.offsets = {}; buf.swapped = {}; buf.modified = false
    buf.nPages = 0; buf.nTotal = 0
    if HL then buf.tLang = HL.detect(sPath) end

    local nByte = 0; local nLIP = 0; local nPN = 1
    local nPSB = 0; local bEndsNL = false

    while true do
        local sC = fs.read(h, 4096); if not sC then break end
        bEndsNL = false
        for i = 1, #sC do
            if sC:byte(i) == 10 then
                nLIP = nLIP + 1; buf.nTotal = buf.nTotal + 1; bEndsNL = true
                if nLIP >= PAGE_SZ then
                    buf.meta[nPN] = nLIP
                    buf.offsets[nPN] = {nPSB, nByte + i - nPSB}
                    nPN = nPN + 1; nPSB = nByte + i; nLIP = 0
                end
            else bEndsNL = false end
        end
        nByte = nByte + #sC
    end
    fs.close(h)

    if not bEndsNL and nByte > 0 then nLIP = nLIP + 1; buf.nTotal = buf.nTotal + 1 end
    if nLIP > 0 then
        buf.meta[nPN] = nLIP; buf.offsets[nPN] = {nPSB, nByte - nPSB}
    elseif buf.nTotal == 0 then
        buf.meta[1] = 1; buf.offsets[1] = {0, 0}; nPN = 1; buf.nTotal = 1
    end
    buf.nPages = nPN
    return true
end

local function saveFile(sPath)
    sPath = sPath or buf.sPath
    if not sPath then return false, "No filename" end
    local h = fs.open(sPath, "w")
    if not h then return false, "Cannot write: " .. sPath end
    for nP = 1, buf.nPages do
        if (buf.meta[nP] or 0) > 0 then
            local tL
            if buf.cache[nP] then tL = buf.cache[nP].lines
            elseif buf.swapped[nP] then tL = readSwap(nP)
            else tL = readOrigPage(nP) end
            for i, s in ipairs(tL) do
                fs.write(h, s); fs.write(h, "\n")
            end
            if not buf.cache[nP] then tL = nil end
        end
        syscall("process_yield")
    end
    fs.close(h)
    -- Cleanup swap files
    for nP in pairs(buf.swapped) do
        fs.remove(SWAP_DIR .. "/p" .. nP)
    end
    buf.swapped = {}
    for _, pg in pairs(buf.cache) do pg.dirty = false end
    buf.modified = false; buf.sPath = sPath
    -- Re-index from saved file
    local tOldCache = buf.cache; local tOldLru = buf.lru
    local nOldCached = buf.nCached
    openFile(sPath)
    -- Restore cache (content matches saved file)
    buf.cache = tOldCache; buf.lru = tOldLru; buf.nCached = nOldCached
    return true
end

-- =============================================
-- 4. EDITOR STATE
-- =============================================

local nCL, nCC = 1, 1   -- cursor line, col
local nTop, nLeft = 1, 1 -- viewport
local sMode   = "normal"
local sCmdBuf = ""
local sSearch = ""
local sTerm   = ""
local sMsg    = ""
local sYank   = ""
local bYLine  = false
local bRun    = true
local sPend   = nil

local tUndo = {}

local function undoPush(op, ln, old)
    tUndo[#tUndo+1] = {op=op, ln=ln, old=old}
    while #tUndo > MAX_UNDO do table.remove(tUndo, 1) end
end
local function undoPop()
    if #tUndo == 0 then sMsg = "Already at oldest change"; return end
    local u = table.remove(tUndo)
    if u.op == "set" then setLine(u.ln, u.old)
    elseif u.op == "ins" then deleteLine(u.ln)
    elseif u.op == "del" then insertLine(u.ln - 1, u.old) end
    buf.modified = true
end

local function clamp(n, lo, hi) return math.max(lo, math.min(hi, n)) end
local function curL() return getLine(nCL) end
local function fixCol()
    local mx = #curL()
    if sMode == "normal" then mx = math.max(1, mx) end
    if sMode == "insert" then mx = mx + 1 end
    nCC = clamp(nCC, 1, mx)
end

-- =============================================
-- 5. XE CONTEXT
-- =============================================

local ctx = xe.createContext({
    theme = xe.THEMES.dark,
    extensions = {
        "XE_ui_shadow_buffering_render_batch",
        "XE_ui_diff_render_feature",
        "XE_ui_alt_screen_query",
        "XE_ui_deferred_clear",
        "XE_ui_dirty_row_tracking",
        "XE_ui_run_length_grouping",
        "XE_ui_toast",
    },
})
if not ctx then print("xvi: no XE context"); return end
local W, H = ctx.W, ctx.H
local EDIT_H = H - 1
local STATUS_Y = H

-- Colors
local C = {
    bg=0x0A0A1A, fg=0xCCCCDD, gut=0x555566, gutBg=0x0E0E22,
    curLn=0x141430, cursor=0xFFFFFF, tilde=0x333355,
    barBg=0x0D2B52, barFg=0xFFFFFF,
    modeN=0x55FF55, modeI=0xFF5555, modeC=0x5599FF,
}

-- =============================================
-- 6. RENDERING
-- =============================================

local function gutW()
    return #tostring(buf.nTotal) + 2
end

local function ensureVis()
    if nCL < nTop + SCROLL_OFF then nTop = math.max(1, nCL - SCROLL_OFF) end
    if nCL >= nTop + EDIT_H - SCROLL_OFF then nTop = nCL - EDIT_H + SCROLL_OFF + 1 end
    local tw = W - gutW()
    if nCC < nLeft then nLeft = nCC end
    if nCC >= nLeft + tw then nLeft = nCC - tw + 1 end
end

local function render()
    ensureVis()
    ctx:clear(C.bg)
    local gw = gutW()
    local tw = W - gw

    -- Pre-fill gutter and edit area
    ctx:fill(1, 1, gw, EDIT_H, " ", C.gut, C.gutBg)
    ctx:fill(gw + 1, 1, tw, EDIT_H, " ", C.fg, C.bg)

    -- Compute block-comment state for visible range (lightweight)
    local tBS = {}
    if HL and buf.tLang and buf.tLang.blockComment then
        -- Only compute for visible lines ± margin
        local nFrom = math.max(1, nTop - 20)
        local nTo = math.min(buf.nTotal, nTop + EDIT_H + 5)
        local bIn = false
        local sBS = buf.tLang.blockComment[1]
        local sBE = buf.tLang.blockComment[2]
        for i = nFrom, nTo do
            tBS[i] = bIn
            local s = getLine(i); local p = 1
            while p <= #s do
                if bIn then
                    local e = s:find(sBE, p, true)
                    if e then bIn = false; p = e + #sBE else break end
                else
                    if sBS and p + #sBS - 1 <= #s and s:sub(p, p + #sBS - 1) == sBS then
                        bIn = true; p = p + #sBS
                    else p = p + 1 end
                end
            end
        end
    end

    for row = 1, EDIT_H do
        local nLine = nTop + row - 1
        if nLine > buf.nTotal then
            ctx:text(gw + 1, row, "~", C.tilde, C.bg)
        else
            local sLine = getLine(nLine)
            local bCur = (nLine == nCL)
            local nBg = bCur and C.curLn or C.bg

            -- Gutter
            local sN = tostring(nLine)
            ctx:text(1, row, string.rep(" ", gw - 1 - #sN) .. sN .. " ", C.gut, C.gutBg)

            -- Current line bg
            if bCur then ctx:fill(gw + 1, row, tw, 1, " ", C.fg, C.curLn) end

            -- Content
            if HL and buf.tLang and buf.tLang.name ~= "Text"
               and computer.freeMemory() > 49152 then
                local bIB = tBS[nLine] or false
                local tSegs = HL.segments(sLine, nLeft, tw, buf.tLang, bIB)
                local nX = gw + 1
                for _, seg in ipairs(tSegs) do
                    ctx:text(nX, row, seg[1], seg[2], nBg)
                    nX = nX + #seg[1]
                end
            else
                local sV = ""
                if #sLine >= nLeft then sV = sLine:sub(nLeft, nLeft + tw - 1) end
                if #sV < tw then sV = sV .. string.rep(" ", tw - #sV) end
                ctx:text(gw + 1, row, sV, C.fg, nBg)
            end

            -- Cursor
            if bCur then
                local cX = gw + nCC - nLeft + 1
                if cX >= gw + 1 and cX <= gw + tw then
                    local cC = (nCC <= #sLine) and sLine:sub(nCC, nCC) or " "
                    ctx:text(cX, row, cC, C.bg, C.cursor)
                end
            end

            -- Search highlight
            if #sTerm > 0 and sLine:find(sTerm, 1, true) then
                local p = 1
                while true do
                    local f = sLine:find(sTerm, p, true)
                    if not f then break end
                    local sX = gw + f - nLeft + 1
                    if sX + #sTerm - 1 >= gw + 1 and sX <= gw + tw then
                        local vis = sTerm
                        if f < nLeft then vis = vis:sub(nLeft - f + 1) end
                        if #vis > 0 then
                            ctx:text(math.max(sX, gw+1), row, vis:sub(1, tw), 0x000000, 0xFFFF00)
                        end
                    end
                    p = f + 1
                end
            end
        end
    end

    -- Status bar
    ctx:fill(1, STATUS_Y, W, 1, " ", C.barFg, C.barBg)
    local tM = {normal={" NORMAL ",C.modeN}, insert={" INSERT ",C.modeI},
                command={" COMMAND ",C.modeC}, search={" SEARCH ",C.modeC}}
    local m = tM[sMode] or {" ? ", C.barFg}
    ctx:text(1, STATUS_Y, m[1], C.bg, m[2])
    local nX = #m[1] + 2
    local sN = buf.sPath and (buf.sPath:match("[^/]+$") or buf.sPath) or "[No Name]"
    local sMod = buf.modified and " [+]" or ""
    ctx:text(nX, STATUS_Y, sN .. sMod, C.barFg, C.barBg)

    -- Right side: position + memory
    local nFree = math.floor(computer.freeMemory() / 1024)
    local sR = string.format("Ln %d/%d Col %d  %dKB ", nCL, buf.nTotal, nCC, nFree)
    ctx:text(W - #sR + 1, STATUS_Y, sR, C.barFg, C.barBg)

    -- Message or command line
    if sMode == "command" then
        ctx:textPad(1, STATUS_Y, W, ":" .. sCmdBuf .. "_", C.fg, C.bg)
    elseif sMode == "search" then
        ctx:textPad(1, STATUS_Y, W, "/" .. sSearch .. "_", C.fg, C.bg)
    elseif #sMsg > 0 then
        ctx:text(1, STATUS_Y, sMsg, C.barFg, C.barBg)
        sMsg = ""
    end
end

-- =============================================
-- 7. SEARCH
-- =============================================

local function searchFwd(from, col)
    if #sTerm == 0 then return nil end
    for i = from, buf.nTotal do
        local p = getLine(i):find(sTerm, (i == from) and (col + 1) or 1, true)
        if p then return i, p end
    end
    for i = 1, from do
        local p = getLine(i):find(sTerm, 1, true)
        if p then return i, p end
    end
end

local function searchBwd(from, col)
    if #sTerm == 0 then return nil end
    for i = from, 1, -1 do
        local s = getLine(i)
        local mx = (i == from) and (col - 1) or #s
        local last, f = nil, 1
        while true do
            local p = s:find(sTerm, f, true)
            if not p or p > mx then break end
            last = p; f = p + 1
        end
        if last then return i, last end
    end
end

-- =============================================
-- 8. WORD MOTION
-- =============================================

local function nextWord(s, c)
    while c <= #s and s:sub(c,c) ~= " " do c = c + 1 end
    while c <= #s and s:sub(c,c) == " " do c = c + 1 end
    return c
end
local function prevWord(s, c)
    c = c - 1
    while c > 1 and s:sub(c,c) == " " do c = c - 1 end
    while c > 1 and s:sub(c-1,c-1) ~= " " do c = c - 1 end
    return c
end

-- =============================================
-- 9. NORMAL MODE
-- =============================================

local function handleNormal(k)
    if sPend == "g" then
        sPend = nil
        if k == "g" then nCL = 1; nCC = 1; fixCol() end
        return
    end
    if sPend == "d" then
        sPend = nil
        if k == "d" then
            undoPush("del", nCL, getLine(nCL))
            sYank = getLine(nCL); bYLine = true
            deleteLine(nCL)
            nCL = clamp(nCL, 1, buf.nTotal); fixCol()
        end; return
    end
    if sPend == "y" then
        sPend = nil
        if k == "y" then sYank = getLine(nCL); bYLine = true; sMsg = "1 line yanked" end
        return
    end

    if     k == "h" or k == "\27[D" then nCC = nCC - 1; fixCol()
    elseif k == "l" or k == "\27[C" then nCC = nCC + 1; fixCol()
    elseif k == "j" or k == "\27[B" then nCL = math.min(nCL + 1, buf.nTotal); fixCol()
    elseif k == "k" or k == "\27[A" then nCL = math.max(nCL - 1, 1); fixCol()
    elseif k == "0" or k == "\27[H" then nCC = 1
    elseif k == "$" or k == "\27[F" then nCC = #curL(); fixCol()
    elseif k == "w" then nCC = nextWord(curL(), nCC); fixCol()
    elseif k == "b" then nCC = prevWord(curL(), nCC); fixCol()
    elseif k == "G" then nCL = buf.nTotal; fixCol()
    elseif k == "g" then sPend = "g"
    elseif k == "\27[5~" then nCL = math.max(1, nCL - EDIT_H); fixCol()
    elseif k == "\27[6~" then nCL = math.min(buf.nTotal, nCL + EDIT_H); fixCol()
    elseif k == "i" then undoPush("set", nCL, curL()); sMode = "insert"
    elseif k == "a" then
        undoPush("set", nCL, curL()); sMode = "insert"
        if #curL() > 0 then nCC = nCC + 1 end
    elseif k == "A" then undoPush("set", nCL, curL()); sMode = "insert"; nCC = #curL() + 1
    elseif k == "o" then
        local sI = curL():match("^(%s*)") or ""
        insertLine(nCL, sI)
        undoPush("ins", nCL + 1, nil)
        nCL = nCL + 1; nCC = #sI + 1; sMode = "insert"
    elseif k == "O" then
        insertLine(nCL - 1, "")
        undoPush("ins", nCL, nil)
        nCC = 1; sMode = "insert"
    elseif k == "x" then
        local s = curL()
        if #s > 0 and nCC <= #s then
            undoPush("set", nCL, s)
            setLine(nCL, s:sub(1, nCC-1) .. s:sub(nCC+1))
            fixCol()
        end
    elseif k == "d" then sPend = "d"
    elseif k == "y" then sPend = "y"
    elseif k == "p" then
        if #sYank > 0 then
            if bYLine then
                insertLine(nCL, sYank)
                undoPush("ins", nCL + 1, nil)
                nCL = nCL + 1; nCC = 1
            else
                undoPush("set", nCL, curL())
                local s = curL()
                setLine(nCL, s:sub(1, nCC) .. sYank .. s:sub(nCC+1))
                nCC = nCC + #sYank
            end
            fixCol()
        end
    elseif k == "J" then
        if nCL < buf.nTotal then
            undoPush("set", nCL, curL())
            local nO = #curL()
            setLine(nCL, curL() .. " " .. getLine(nCL + 1))
            deleteLine(nCL + 1)
            nCC = nO + 1
        end
    elseif k == "u" then undoPop()
    elseif k == "/" then sMode = "search"; sSearch = ""
    elseif k == "n" then
        local nl, nc = searchFwd(nCL, nCC)
        if nl then nCL = nl; nCC = nc; fixCol() else sMsg = "Not found" end
    elseif k == "N" then
        local nl, nc = searchBwd(nCL, nCC)
        if nl then nCL = nl; nCC = nc; fixCol() else sMsg = "Not found" end
    elseif k == ":" then sMode = "command"; sCmdBuf = ""
    elseif k == "\7" then
        sMsg = string.format('"%s" %s%dL %dC',
            buf.sPath or "[No Name]",
            buf.modified and "[+] " or "", buf.nTotal, #curL())
    end
end

-- =============================================
-- 10. INSERT MODE
-- =============================================

local function handleInsert(k)
    local s = curL()
    if k == "\27" then sMode = "normal"; nCC = math.max(1, nCC - 1); fixCol(); return end

    if k == "\b" then
        if nCC > 1 then
            setLine(nCL, s:sub(1, nCC-2) .. s:sub(nCC)); nCC = nCC - 1
        elseif nCL > 1 then
            local sPrev = getLine(nCL - 1); nCC = #sPrev + 1
            setLine(nCL - 1, sPrev .. s); deleteLine(nCL); nCL = nCL - 1
        end
    elseif k == "\n" then
        local sI = s:match("^(%s*)") or ""
        setLine(nCL, s:sub(1, nCC - 1))
        insertLine(nCL, sI .. s:sub(nCC))
        nCL = nCL + 1; nCC = #sI + 1
    elseif k == "\t" then
        local sTab = "  "
        setLine(nCL, s:sub(1, nCC-1) .. sTab .. s:sub(nCC)); nCC = nCC + #sTab
    elseif k == "\27[A" then nCL = math.max(1, nCL-1); fixCol()
    elseif k == "\27[B" then nCL = math.min(buf.nTotal, nCL+1); fixCol()
    elseif k == "\27[D" then nCC = math.max(1, nCC-1)
    elseif k == "\27[C" then nCC = math.min(#s+1, nCC+1)
    elseif k == "\27[H" then nCC = 1
    elseif k == "\27[F" then nCC = #s + 1
    elseif k and #k == 1 and k:byte() >= 32 and k:byte() < 127 then
        setLine(nCL, s:sub(1, nCC-1) .. k .. s:sub(nCC)); nCC = nCC + 1
    end
end

-- =============================================
-- 11. COMMAND MODE
-- =============================================

local function execCmd(sCmd)
    local sC = sCmd:match("^(%S+)")
    local sA = sCmd:match("^%S+%s+(.+)$")
    if sC == "w" or sC == "write" then
        if sA then buf.sPath = sA end
        local ok, err = saveFile(buf.sPath)
        if ok then ctx:toastSuccess("Written: " .. (buf.sPath:match("[^/]+$") or buf.sPath))
        else ctx:toastError(err or "Write failed") end
    elseif sC == "q" or sC == "quit" then
        if buf.modified then sMsg = "Unsaved changes (use :q!)"
        else bRun = false end
    elseif sC == "q!" then bRun = false
    elseif sC == "wq" or sC == "x" then
        if sA then buf.sPath = sA end
        local ok = saveFile(buf.sPath)
        if ok then bRun = false else ctx:toastError("Write failed") end
    elseif sC == "e" or sC == "edit" then
        if sA then
            local ok, err = openFile(sA)
            if ok then nCL = 1; nCC = 1; nTop = 1; nLeft = 1
                ctx:toastSuccess((buf.sPath:match("[^/]+$") or sA) .. " — " .. buf.nTotal .. "L")
            else ctx:toastError(err or "Open failed") end
        else sMsg = "Usage: :e <path>" end
    elseif sC == "qa" or sC == "qall" then bRun = false
    elseif tonumber(sC) then
        nCL = clamp(tonumber(sC), 1, buf.nTotal); fixCol()
    else sMsg = "Unknown: " .. sCmd end
end

local function handleCommand(k)
    if k == "\27" then sMode = "normal"; return end
    if k == "\n" then sMode = "normal"; execCmd(sCmdBuf); sCmdBuf = ""; return end
    if k == "\b" then
        if #sCmdBuf > 0 then sCmdBuf = sCmdBuf:sub(1, -2)
        else sMode = "normal" end
    elseif k and #k == 1 and k:byte() >= 32 then sCmdBuf = sCmdBuf .. k end
end

-- =============================================
-- 12. SEARCH MODE
-- =============================================

local function handleSearch(k)
    if k == "\27" then sMode = "normal"; return end
    if k == "\n" then
        sMode = "normal"; sTerm = sSearch; sSearch = ""
        local nl, nc = searchFwd(nCL, nCC)
        if nl then nCL = nl; nCC = nc; fixCol()
        else sMsg = "Not found: " .. sTerm end
        return
    end
    if k == "\b" then
        if #sSearch > 0 then sSearch = sSearch:sub(1, -2) else sMode = "normal" end
    elseif k and #k == 1 and k:byte() >= 32 then sSearch = sSearch .. k end
end

-- =============================================
-- 13. INIT: OPEN FILE
-- =============================================

local sArg = nil
for _, a in ipairs(tArgs) do
    if a:sub(1,1) ~= "-" then sArg = a; break end
end

if sArg then
    local ok, err = openFile(sArg)
    if ok then
        ctx:toastInfo((buf.sPath:match("[^/]+$") or sArg) .. " — " .. buf.nTotal .. "L, " ..
            buf.nPages .. " pages")
    else
        ctx:toastError(err or "Open failed")
        buf.meta = {1}; buf.nPages = 1; buf.nTotal = 1
        buf.offsets = {[1]={0,0}}
        buf.cache = {[1]={lines={""}, dirty=false}}; buf.nCached = 1
        buf.lru = {1}
    end
else
    buf.meta = {1}; buf.nPages = 1; buf.nTotal = 1
    buf.offsets = {[1]={0,0}}
    buf.cache = {[1]={lines={""}, dirty=false}}; buf.nCached = 1
    buf.lru = {1}
end

-- =============================================
-- 14. MAIN LOOP
-- =============================================

while bRun do
    ctx:beginFrame()
    render()
    local k = ctx:key()
    if k then
        if k == "\3" then
            if sMode ~= "normal" then sMode = "normal"; fixCol()
            else bRun = false end
        elseif sMode == "normal" then handleNormal(k)
        elseif sMode == "insert" then handleInsert(k)
        elseif sMode == "command" then handleCommand(k)
        elseif sMode == "search" then handleSearch(k)
        end
    end
    ctx:endFrame()
end

-- =============================================
-- 15. CLEANUP
-- =============================================

-- Remove swap files
for nP in pairs(buf.swapped) do
    pcall(fs.remove, SWAP_DIR .. "/p" .. nP)
end
pcall(fs.remove, SWAP_DIR)
buf.cache = nil; buf.meta = nil; buf.offsets = nil

ctx:destroy()