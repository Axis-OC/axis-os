--
-- /lib/vi/lang_log.lua
-- Log / VBL syntax definition for xevi
-- Custom colorizer (pattern-based, not keyword-based)
--
local L = {}

L.name         = "Log"
L.lineComment  = nil
L.blockComment = nil
L.operators    = ""
L.keywords     = {}
L.builtins     = {}

-- Color palette for log elements
local C_TIMESTAMP = 0x888899
local C_OK        = 0x55FF55
local C_FAIL      = 0xFF5555
local C_WARN      = 0xFFFF55
local C_INFO      = 0x55DDDD
local C_SEC       = 0xFF55FF
local C_DEBUG     = 0x777777
local C_DEV       = 0x5555FF
local C_SCHED     = 0x55AAFF
local C_DRV       = 0xFFAA55
local C_VFS       = 0x55FFAA
local C_MEM       = 0xFFFF55
local C_PROC      = 0xAAFFAA
local C_PID       = 0xAAAADD
local C_PATH      = 0xCCBBAA
local C_NUMBER    = 0x99DD77
local C_BRACKET   = 0x666688
local C_STRING    = 0xDD9955
local C_BORDER    = 0x555577
local C_ACCENT    = 0x55FFFF

local tLevelColors = {
  ["OK"]    = C_OK,
  ["FAIL"]  = C_FAIL,
  ["WARN"]  = C_WARN,
  ["INFO"]  = C_INFO,
  ["SEC"]   = C_SEC,
  ["DEBUG"] = C_DEBUG,
  ["DEV"]   = C_DEV,
  ["SCHED"] = C_SCHED,
  ["DRV"]   = C_DRV,
  ["VFS"]   = C_VFS,
  ["MEM"]   = C_MEM,
  ["PROC"]  = C_PROC,
  ["IPC"]   = 0xAAAAFF,
  ["DK"]    = C_DRV,
  ["HVCI"]  = C_SEC,
  ["PG"]    = C_SEC,
  ["PM"]    = C_INFO,
  ["GDI"]   = 0x55AAFF,
  ["EXSi"]  = C_SEC,
}

--- Custom colorizer: returns tC[1..nLen] of color values.
-- Called by highlight.lua's H.colorize when tLang.colorize exists.
function L.colorize(sLine, H)
  local nLen = #sLine
  if nLen == 0 then return {} end

  local tC = {}
  local C_DEFAULT = H.C_DEFAULT
  for i = 1, nLen do tC[i] = C_DEFAULT end

  local function paint(nFrom, nTo, nColor)
    for i = math.max(1, nFrom), math.min(nTo, nLen) do tC[i] = nColor end
  end

  -- ── Timestamp: [  9.1234] ──
  local tsS, tsE = sLine:find("^%[%s*%d+%.%d+%]")
  if tsS then
    paint(tsS, tsE, C_TIMESTAMP)
  end

  -- ── Level tag: [  OK  ] [ FAIL ] [ INFO ] etc. ──
  for sLevel, nColor in pairs(tLevelColors) do
    -- Match bracketed level tags like [  OK  ] or [ INFO ] or [DEBUG ]
    local lS, lE = sLine:find("%[%s*" .. sLevel .. "%s*%]")
    if lS then paint(lS, lE, nColor) end
    -- Also match unbracketed [LEVEL] patterns like [PM], [DK], [GDI]
    lS, lE = sLine:find("%[" .. sLevel .. "%]")
    if lS then paint(lS, lE, nColor) end
  end

  -- ── PID references: PID=5, P3, PID 12 ──
  for pS, pE in sLine:gmatch("()PID[= ](%d+)") do
    -- pS is the position of 'P', find the digit end
  end
  -- Simpler approach: scan for PID patterns
  local pos = 1
  while pos <= nLen do
    -- PID=N or P N (short form)
    local pS, pE = sLine:find("PID=%-?%d+", pos)
    if pS then
      paint(pS, pS + 2, C_PID)     -- "PID"
      paint(pS + 3, pE, C_NUMBER)  -- "=N"
      pos = pE + 1
    else
      pS, pE = sLine:find("P%-?%d+%s", pos)
      if pS and (pos == 1 or sLine:sub(pS-1, pS-1):match("[^%w_]")) then
        paint(pS, pS, C_PID)
        paint(pS + 1, pE - 1, C_NUMBER)
        pos = pE
      else
        break
      end
    end
  end

  -- ── File paths: /lib/something.lua ──
  for pS, pPath, pE in sLine:gmatch("()/[%w_%./-]+%.%w+()" ) do
    paint(pS, pE - 1, C_PATH)
  end

  -- ── Hex numbers: 0xABCD ──
  for pS, pE in sLine:gmatch("()0x%x+()" ) do
    paint(pS, pE - 1, C_NUMBER)
  end

  -- ── Plain numbers (not already colored) ──
  for pS, pE in sLine:gmatch("()%d+()") do
    -- Only color if not already part of a colored region
    if tC[pS] == C_DEFAULT then
      paint(pS, pE - 1, C_NUMBER)
    end
  end

  -- ── Quoted strings ──
  for pS, pE in sLine:gmatch('()"[^"]*"()') do
    paint(pS, pE - 1, C_STRING)
  end
  for pS, pE in sLine:gmatch("()'[^']*'()") do
    paint(pS, pE - 1, C_STRING)
  end

  -- ── Box-drawing borders: ╔═╗║╚╝ and +=-| ──
  for i = 1, nLen do
    local ch = sLine:sub(i, i)
    if ch == "+" or ch == "|" then
      if tC[i] == C_DEFAULT then tC[i] = C_BORDER end
    end
  end
  -- Multi-byte box chars (UTF-8)
  for pS, pE in sLine:gmatch("()[\226][\149\148][\128-\191]+()") do
    paint(pS, pE - 1, C_BORDER)
  end

  -- ── Special markers ──
  for pS, pE in sLine:gmatch("()PASS()") do paint(pS, pE-1, C_OK) end
  for pS, pE in sLine:gmatch("()FAIL()") do paint(pS, pE-1, C_FAIL) end
  for pS, pE in sLine:gmatch("()ERROR()") do paint(pS, pE-1, C_FAIL) end
  for pS, pE in sLine:gmatch("()WARNING()") do paint(pS, pE-1, C_WARN) end
  for pS, pE in sLine:gmatch("()BLOCKED()") do paint(pS, pE-1, C_FAIL) end
  for pS, pE in sLine:gmatch("()QUARANTINE[D]?()") do paint(pS, pE-1, C_SEC) end
  for pS, pE in sLine:gmatch("()VERIFIED()") do paint(pS, pE-1, C_OK) end
  for pS, pE in sLine:gmatch("()ARMED()") do paint(pS, pE-1, C_OK) end
  for pS, pE in sLine:gmatch("()PANIC()") do paint(pS, pE-1, C_FAIL) end

  -- ── Section headers: === ... === ──
  if sLine:match("^=+$") or sLine:match("^%-%-%-") then
    paint(1, nLen, C_BORDER)
  end

  return tC
end

return L