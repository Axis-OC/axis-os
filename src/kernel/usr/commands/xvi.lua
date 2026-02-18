--
-- /usr/commands/vi.lua
-- xvi — AxisOS visual editor
-- Batch-rendered, alt-screen, diff-based updates.
--

local fs = require("filesystem")
local tArgs = env.ARGS or {}

local hIn  = fs.open("/dev/tty", "r")
local hOut = fs.open("/dev/tty", "w")
if not hIn or not hOut then print("vi: no tty"); return end

fs.deviceControl(hIn, "set_mode", {"raw"})
local bSzOk, tSz = fs.deviceControl(hIn, "get_size", {})
local W = (bSzOk and tSz and tSz.w) or 80
local H = (bSzOk and tSz and tSz.h) or 25

-- =============================================
-- SCREEN ABSTRACTION (batch + diff)
-- =============================================

local SCR = {
  prev = {},   -- [y] = change-detection key
  batch = {},  -- pending {x, y, text, fg, bg} ops
}

function SCR.init()
  fs.deviceControl(hIn, "enter_alt_screen", {})
  SCR.prev = {}
end

function SCR.done()
  fs.deviceControl(hIn, "leave_alt_screen", {})
end

function SCR.put(x, y, text, fg, bg)
  SCR.batch[#SCR.batch + 1] = {x, y, text, fg or 0xFFFFFF, bg or 0x000000}
end

-- Write a full row — skip if unchanged since last frame
function SCR.row(y, text, fg, bg)
  fg = fg or 0xFFFFFF; bg = bg or 0x000000
  if #text < W then text = text .. string.rep(" ", W - #text) end
  if #text > W then text = text:sub(1, W) end
  local sKey = text .. tostring(fg) .. tostring(bg)
  if SCR.prev[y] == sKey then return end
  SCR.prev[y] = sKey
  SCR.put(1, y, text, fg, bg)
end

-- Write a multi-segment row (e.g. line number + content)
function SCR.segs(y, tSegs)
  local tK = {}
  for _, s in ipairs(tSegs) do
    tK[#tK + 1] = s[1] .. tostring(s[2] or 0) .. tostring(s[3] or 0)
  end
  local sKey = table.concat(tK, "|")
  if SCR.prev[y] == sKey then return end
  SCR.prev[y] = sKey

  local nX = 1
  for _, s in ipairs(tSegs) do
    SCR.put(nX, y, s[1], s[2] or 0xFFFFFF, s[3] or 0x000000)
    nX = nX + #s[1]
  end
  if nX <= W then
    SCR.put(nX, y, string.rep(" ", W - nX + 1), 0xFFFFFF, 0x000000)
  end
end

function SCR.flush()
  if #SCR.batch > 0 then
    fs.deviceControl(hIn, "render_batch", SCR.batch)
    SCR.batch = {}
  end
end

function SCR.invalidate() SCR.prev = {} end

-- =============================================
-- EDITOR STATE
-- =============================================

local sFilePath  = nil
local tLines     = {""}
local bModified  = false
local sMode      = "normal"
local sMsg       = ""
local sCmdBuf    = ""
local sSearchBuf = ""
local sSearchTerm= ""
local sYankBuf   = ""
local bYankLine  = false

local nCL, nCC   = 1, 1
local nTop, nLeft = 1, 1
local bLineNum = false
local nNumW    = 0
local nViewH   = H - 2

local sPending = nil
local tUndo    = {}
local MAX_UNDO = 50

-- =============================================
-- SYNTAX HIGHLIGHTING
-- =============================================

local HL = nil
pcall(function() HL = require("vi/highlight") end)

local tLang      = nil   -- language definition
local tBlkState  = {}    -- [lineNum] = true if inside block comment
local bStateDirty = true -- recompute before next render

local function recomputeState()
  if HL and tLang then
    tBlkState = HL.computeState(tLines, tLang)
  end
  bStateDirty = false
end

local function markDirty()
  markDirty()
  bStateDirty = true
end

-- =============================================
-- UNDO
-- =============================================

local function pushUndo()
  local t = {}; for i,s in ipairs(tLines) do t[i]=s end
  table.insert(tUndo, {l=t, cl=nCL, cc=nCC})
  if #tUndo > MAX_UNDO then table.remove(tUndo, 1) end
end

local function popUndo()
  if #tUndo == 0 then sMsg="Already at oldest change"; return end
  local t = table.remove(tUndo)
  tLines=t.l; nCL=t.cl; nCC=t.cc; bModified=true
end

-- =============================================
-- FILE I/O (loop read for large files)
-- =============================================

local function loadFile(sPath)
  local h = fs.open(sPath, "r")
  if not h then return nil end
  local tChunks = {}
  while true do
    local s = fs.read(h, math.huge)
    if not s then break end
    tChunks[#tChunks + 1] = s
  end
  fs.close(h)
  local sAll = table.concat(tChunks)
  if #sAll == 0 then return {""} end
  local t = {}
  for sLine in (sAll .. "\n"):gmatch("([^\n]*)\n") do
    t[#t + 1] = sLine:gsub("\r", "")    -- strip CR from CRLF files
  end
  if #t > 1 and t[#t] == "" then t[#t] = nil end
  if #t == 0 then t[1] = "" end
  return t
end

local function saveFile(sPath)
  if not sPath then return false, "No filename" end
  local h = fs.open(sPath, "w")
  if not h then return false, "Cannot write: " .. sPath end
  fs.write(h, table.concat(tLines, "\n") .. "\n")
  fs.close(h)
  bModified = false; return true
end

if tArgs[1] then
  sFilePath = tArgs[1]
  if sFilePath:sub(1,1) ~= "/" then
    sFilePath = (env.PWD or "/") .. "/" .. sFilePath
  end
  sFilePath = sFilePath:gsub("//", "/")
  local t = loadFile(sFilePath)
  if t then tLines = t; sMsg = '"' .. sFilePath .. '" ' .. #tLines .. "L"
  else sMsg = '"' .. sFilePath .. '" [New]' end
end

-- Detect syntax from file extension
if HL then
  tLang = HL.detect(sFilePath)
  if tLang and tLang.name ~= "Text" then
    sMsg = sMsg .. " [" .. tLang.name .. "]"
  end
else
  tLang = nil
end
bStateDirty = true

-- =============================================
-- HELPERS
-- =============================================

local function clamp(n, lo, hi) return math.max(lo, math.min(hi, n)) end
local function curLine() return tLines[nCL] or "" end

local function fixCol()
  local nMax = #curLine()
  if sMode == "normal" then nMax = math.max(1, nMax) end
  if sMode == "insert" then nMax = nMax + 1 end
  nCC = clamp(nCC, 1, nMax)
end

local function ensureVisible()
  if nCL < nTop then nTop = nCL end
  if nCL >= nTop + nViewH then nTop = nCL - nViewH + 1 end
  local nTextW = W - nNumW
  if nCC < nLeft then nLeft = nCC end
  if nCC >= nLeft + nTextW then nLeft = nCC - nTextW + 1 end
end

local function updateLineNum() nNumW = bLineNum and 5 or 0 end

local function readKey() return fs.read(hIn) end

local function nextWord(s, c)
  while c <= #s and s:sub(c,c) ~= " " do c=c+1 end
  while c <= #s and s:sub(c,c) == " " do c=c+1 end; return c
end

local function prevWord(s, c)
  c = c - 1
  while c > 1 and s:sub(c,c) == " " do c=c-1 end
  while c > 1 and s:sub(c-1,c-1) ~= " " do c=c-1 end; return c
end

local function searchFwd(sTerm, nSL, nSC)
  if not sTerm or #sTerm == 0 then return nil end
  for i = nSL, #tLines do
    local nF = (i == nSL) and (nSC + 1) or 1
    local p = tLines[i]:find(sTerm, nF, true)
    if p then return i, p end
  end
  for i = 1, nSL do
    local p = tLines[i]:find(sTerm, 1, true)
    if p then return i, p end
  end
end

local function searchBwd(sTerm, nSL, nSC)
  if not sTerm or #sTerm == 0 then return nil end
  for i = nSL, 1, -1 do
    local s = tLines[i]; local nMax = (i == nSL) and (nSC - 1) or #s
    local nLast, nFrom = nil, 1
    while true do
      local p = s:find(sTerm, nFrom, true)
      if not p or p > nMax then break end
      nLast = p; nFrom = p + 1
    end
    if nLast then return i, nLast end
  end
end

-- =============================================
-- RENDERING (diff-based, one batch per frame)
-- =============================================

local nPrevCursorY = nil  -- track cursor row for invalidation

local function render()
  ensureVisible(); updateLineNum()
  local nTextW = W - nNumW

  -- Invalidate row where cursor WAS (so old cursor block is redrawn)
  if nPrevCursorY then SCR.prev[nPrevCursorY] = nil end

-- Recompute block comment state if file changed
  if bStateDirty then recomputeState() end

  -- Content rows
  for row = 1, nViewH do
    local nLine = nTop + row - 1
    if nLine <= #tLines then
      local tS = {}
      if bLineNum then
        local sN = tostring(nLine)
        tS[#tS + 1] = {string.rep(" ", nNumW - 1 - #sN) .. sN .. " ", 0x555555, 0x000000}
      end

      -- Syntax-highlighted segments for visible portion
      local sL = tLines[nLine]
      if HL and tLang then
        local bInBlk = tBlkState[nLine] or false
        local tHL = HL.segments(sL, nLeft, nTextW, tLang, bInBlk)
        for _, seg in ipairs(tHL) do
          tS[#tS + 1] = seg
        end
      else
        local sV = (#sL >= nLeft) and sL:sub(nLeft, nLeft + nTextW - 1) or ""
        if #sV < nTextW then sV = sV .. string.rep(" ", nTextW - #sV) end
        tS[#tS + 1] = {sV, 0xFFFFFF, 0x000000}
      end

      SCR.segs(row, tS)
    else
      local tS = {}
      if bLineNum then tS[#tS + 1] = {string.rep(" ", nNumW), 0x000000, 0x000000} end
      tS[#tS + 1] = {"~", 0x0000FF, 0x000000}
      tS[#tS + 1] = {string.rep(" ", math.max(0, nTextW - 1)), 0x000000, 0x000000}
      SCR.segs(row, tS)
    end
  end

  -- Status bar
  local sTag = ({normal=" NORMAL ", insert=" INSERT ",
                  command=" COMMAND ", search=" SEARCH "})[sMode] or " ? "
  local sN = sFilePath or "[No Name]"
  if #sN > 30 then sN = "..." .. sN:sub(-27) end
  local sLangTag = (tLang and tLang.name ~= "Text") and (" " .. tLang.name .. " ") or ""
  local sL = sTag .. " " .. sN .. (bModified and " [+]" or "") .. sLangTag
  local sR = string.format(" Ln %d/%d Col %d ", nCL, #tLines, nCC)
  local nMid = math.max(0, W - #sL - #sR)
  SCR.row(H - 1, sL .. string.rep(" ", nMid) .. sR, 0xFFFFFF, 0x0000AA)

  -- Message / command line
  local sCmd = ""
  if sMode == "command" then sCmd = ":" .. sCmdBuf
  elseif sMode == "search" then sCmd = "/" .. sSearchBuf
  else sCmd = sMsg; sMsg = "" end
  SCR.row(H, sCmd, 0xFFFFFF, 0x000000)

  -- Cursor (always sent — inverted block overlay)
  local nSY, nSX
  if sMode == "command" then     nSY = H; nSX = 2 + #sCmdBuf
  elseif sMode == "search" then  nSY = H; nSX = 2 + #sSearchBuf
  else nSY = nCL - nTop + 1; nSX = (nCC - nLeft + 1) + nNumW end

  if nSY >= 1 and nSY <= H and nSX >= 1 and nSX <= W then
    local sC = " "
    if sMode ~= "command" and sMode ~= "search" then
      local sL2 = tLines[nCL] or ""
      if nCC >= 1 and nCC <= #sL2 then sC = sL2:sub(nCC, nCC) end
    end
    SCR.put(nSX, nSY, sC, 0x000000, 0xFFFFFF)
    -- Invalidate cursor row so next frame redraws content under cursor
    SCR.prev[nSY] = nil
    nPrevCursorY = nSY
  end

  SCR.flush()
end

-- =============================================
-- NORMAL MODE
-- =============================================

local function handleNormal(k)
  if sPending == "g" then
    sPending = nil
    if k == "g" then nCL = 1; nCC = 1; fixCol() end; return
  end
  if sPending == "d" then
    sPending = nil
    if k == "d" then
      pushUndo(); sYankBuf = tLines[nCL]; bYankLine = true
      table.remove(tLines, nCL)
      if #tLines == 0 then tLines[1] = "" end
      nCL = clamp(nCL, 1, #tLines); fixCol(); markDirty()
      SCR.invalidate()  -- line removal changes all rows below
    end; return
  end
  if sPending == "y" then
    sPending = nil
    if k == "y" then sYankBuf = tLines[nCL]; bYankLine = true; sMsg = "1 line yanked" end
    return
  end

  if     k == "h" or k == "\27[D" then nCC = nCC - 1; fixCol()
  elseif k == "l" or k == "\27[C" then nCC = nCC + 1; fixCol()
  elseif k == "j" or k == "\27[B" then nCL = math.min(nCL + 1, #tLines); fixCol()
  elseif k == "k" or k == "\27[A" then nCL = math.max(nCL - 1, 1); fixCol()
  elseif k == "0" or k == "\27[H" then nCC = 1
  elseif k == "$" or k == "\27[F" then nCC = #curLine(); fixCol()
  elseif k == "w" then nCC = nextWord(curLine(), nCC); fixCol()
  elseif k == "b" then nCC = prevWord(curLine(), nCC); fixCol()
  elseif k == "G" then nCL = #tLines; fixCol()
  elseif k == "g" then sPending = "g"
  elseif k == "\27[5~" then nCL = math.max(1, nCL - nViewH); fixCol()
  elseif k == "\27[6~" then nCL = math.min(#tLines, nCL + nViewH); fixCol()
  elseif k == "i" then pushUndo(); sMode = "insert"
  elseif k == "a" then pushUndo(); sMode = "insert"; if #curLine() > 0 then nCC = nCC + 1 end
  elseif k == "A" then pushUndo(); sMode = "insert"; nCC = #curLine() + 1
  elseif k == "o" then
    pushUndo(); table.insert(tLines, nCL + 1, "")
    nCL = nCL + 1; nCC = 1; sMode = "insert"; markDirty(); SCR.invalidate()
  elseif k == "O" then
    pushUndo(); table.insert(tLines, nCL, "")
    nCC = 1; sMode = "insert"; markDirty(); SCR.invalidate()
  elseif k == "x" then
    local s = curLine()
    if #s > 0 and nCC <= #s then
      pushUndo(); tLines[nCL] = s:sub(1,nCC-1)..s:sub(nCC+1); fixCol(); markDirty()
    end
  elseif k == "X" then
    if nCC > 1 then
      pushUndo(); local s = curLine()
      tLines[nCL] = s:sub(1,nCC-2)..s:sub(nCC); nCC = nCC - 1; markDirty()
    end
  elseif k == "D" then
    pushUndo(); sYankBuf = curLine():sub(nCC); bYankLine = false
    tLines[nCL] = curLine():sub(1, nCC - 1); fixCol(); markDirty()
  elseif k == "d" then sPending = "d"
  elseif k == "y" then sPending = "y"
  elseif k == "p" then
    if #sYankBuf > 0 then
      pushUndo()
      if bYankLine then
        table.insert(tLines, nCL + 1, sYankBuf); nCL = nCL + 1; nCC = 1
        SCR.invalidate()
      else
        local s = curLine()
        tLines[nCL] = s:sub(1,nCC)..sYankBuf..s:sub(nCC+1); nCC = nCC + #sYankBuf
      end
      markDirty(); fixCol()
    end
  elseif k == "P" then
    if #sYankBuf > 0 then
      pushUndo()
      if bYankLine then
        table.insert(tLines, nCL, sYankBuf); nCC = 1; SCR.invalidate()
      else
        local s = curLine(); local n = math.max(nCC - 1, 0)
        tLines[nCL] = s:sub(1,n)..sYankBuf..s:sub(n+1); nCC = n + #sYankBuf + 1
      end
      markDirty(); fixCol()
    end
  elseif k == "J" then
    if nCL < #tLines then
      pushUndo(); local nOld = #curLine()
      tLines[nCL] = curLine().." "..tLines[nCL + 1]
      table.remove(tLines, nCL + 1); nCC = nOld + 1; markDirty()
      SCR.invalidate()
    end
  elseif k == "r" then
    local rk = readKey()
    if rk and #rk == 1 and rk:byte() >= 32 then
      local s = curLine()
      if nCC <= #s then
        pushUndo(); tLines[nCL] = s:sub(1,nCC-1)..rk..s:sub(nCC+1); markDirty()
      end
    end
  elseif k == "u" then popUndo(); SCR.invalidate()
  elseif k == "/" then sMode = "search"; sSearchBuf = ""
  elseif k == "n" then
    local nl, nc = searchFwd(sSearchTerm, nCL, nCC)
    if nl then nCL = nl; nCC = nc; fixCol() else sMsg = "Pattern not found" end
  elseif k == "N" then
    local nl, nc = searchBwd(sSearchTerm, nCL, nCC)
    if nl then nCL = nl; nCC = nc; fixCol() else sMsg = "Pattern not found" end
  elseif k == ":" then sMode = "command"; sCmdBuf = ""
  elseif k == "Z" then
    local k2 = readKey()
    if k2 == "Z" then
      if sFilePath then
        local bOk, sErr = saveFile(sFilePath)
        if bOk then return "quit" else sMsg = sErr end
      else sMsg = "No filename" end
    end
  elseif k == string.char(7) then
    sMsg = string.format('"%s" %s%dL',
      sFilePath or "[No Name]", bModified and "[+] " or "", #tLines)
  end
end

-- =============================================
-- INSERT MODE
-- =============================================

local function handleInsert(k)
  if k == "\27" then sMode = "normal"; nCC = math.max(1, nCC - 1); fixCol(); return end
  local s = curLine()
  if k == "\b" then
    if nCC > 1 then
      tLines[nCL] = s:sub(1,nCC-2)..s:sub(nCC); nCC = nCC - 1; markDirty()
    elseif nCL > 1 then
      local sPrev = tLines[nCL - 1]; nCC = #sPrev + 1
      tLines[nCL - 1] = sPrev..s; table.remove(tLines, nCL)
      nCL = nCL - 1; markDirty(); SCR.invalidate()
    end
  elseif k == "\n" then
    tLines[nCL] = s:sub(1, nCC - 1)
    table.insert(tLines, nCL + 1, s:sub(nCC))
    nCL = nCL + 1; nCC = 1; markDirty(); SCR.invalidate()
  elseif k == "\t" then
    tLines[nCL] = s:sub(1,nCC-1).."  "..s:sub(nCC); nCC = nCC + 2; markDirty()
  elseif k == "\27[A" then nCL = math.max(1, nCL - 1); fixCol()
  elseif k == "\27[B" then nCL = math.min(#tLines, nCL + 1); fixCol()
  elseif k == "\27[D" then nCC = math.max(1, nCC - 1)
  elseif k == "\27[C" then nCC = math.min(#s + 1, nCC + 1)
  elseif k == "\27[H" then nCC = 1
  elseif k == "\27[F" then nCC = #s + 1
  elseif k == "\27[5~" then nCL = math.max(1, nCL - nViewH); fixCol()
  elseif k == "\27[6~" then nCL = math.min(#tLines, nCL + nViewH); fixCol()
  elseif #k == 1 and k:byte() >= 32 then
    tLines[nCL] = s:sub(1,nCC-1)..k..s:sub(nCC); nCC = nCC + 1; markDirty()
  end
end

-- =============================================
-- COMMAND MODE
-- =============================================

local function handleCommand(k)
  if k == "\27" then sMode = "normal"; return end
  if k == "\n" then
    sMode = "normal"; local sCmd = sCmdBuf; sCmdBuf = ""
    local sC = sCmd:match("^(%S+)"); local sA = sCmd:match("^%S+%s+(.+)$")
    if sC == "w" or sC == "write" then
      local p = sA or sFilePath; if sA then sFilePath = sA end
      local bOk, sErr = saveFile(p)
      sMsg = bOk and ('"'..p..'" written') or sErr
    elseif sC == "q" or sC == "quit" then
      if bModified then sMsg = "No write since last change (use :q!)" else return "quit" end
    elseif sC == "q!" then return "quit"
    elseif sC == "wq" or sC == "x" then
      local p = sA or sFilePath; if sA then sFilePath = sA end
      local bOk, sErr = saveFile(p)
      if bOk then return "quit" else sMsg = sErr end
    elseif sC == "set" then
      if sArg == "number" or sArg == "nu" then
        bLineNum = true; SCR.invalidate()
      elseif sArg == "nonumber" or sArg == "nonu" then
        bLineNum = false; SCR.invalidate()
      elseif sArg and sArg:sub(1,7) == "syntax=" then
        local sLangName = sArg:sub(8)
        if sLangName == "off" or sLangName == "none" then
          tLang = HL and HL.UNIVERSAL or nil; sMsg = "Syntax: off"
        elseif HL then
          tLang = HL.loadLang(sLangName)
          sMsg = "Syntax: " .. (tLang.name or sLangName)
        end
        bStateDirty = true; SCR.invalidate()
      else sMsg = "Unknown: " .. tostring(sArg) end
    elseif tonumber(sC) then nCL = clamp(tonumber(sC), 1, #tLines); fixCol()
    else sMsg = "Unknown: " .. sCmd end
    return
  elseif k == "\b" then
    if #sCmdBuf > 0 then sCmdBuf = sCmdBuf:sub(1,-2) else sMode = "normal" end
  elseif #k == 1 and k:byte() >= 32 then sCmdBuf = sCmdBuf .. k end
end

-- =============================================
-- SEARCH MODE
-- =============================================

local function handleSearch(k)
  if k == "\27" then sMode = "normal"; return end
  if k == "\n" then
    sMode = "normal"; sSearchTerm = sSearchBuf; sSearchBuf = ""
    local nl, nc = searchFwd(sSearchTerm, nCL, nCC)
    if nl then nCL = nl; nCC = nc; fixCol() else sMsg = "Not found: " .. sSearchTerm end
    return
  elseif k == "\b" then
    if #sSearchBuf > 0 then sSearchBuf = sSearchBuf:sub(1,-2) else sMode = "normal" end
  elseif #k == 1 and k:byte() >= 32 then sSearchBuf = sSearchBuf .. k end
end

-- =============================================
-- MAIN LOOP
-- =============================================

local function main()
  SCR.init()

  while true do
    render()
    local k = readKey()
    if not k then break end

    if k == "\3" then
      if sMode ~= "normal" then sMode = "normal"; fixCol() end
    else
      local sR
      if sMode == "normal" then sR = handleNormal(k)
      elseif sMode == "insert" then handleInsert(k)
      elseif sMode == "command" then sR = handleCommand(k)
      elseif sMode == "search" then handleSearch(k) end
      if sR == "quit" then break end
    end
    if sMode ~= "normal" then sPending = nil end
  end
end

local bOk, sErr = pcall(main)
SCR.done()
fs.deviceControl(hIn, "set_mode", {"cooked"})
fs.close(hIn); fs.close(hOut)
if not bOk then print("vi: " .. tostring(sErr)) end