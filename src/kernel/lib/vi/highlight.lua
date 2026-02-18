--
-- /lib/vi/highlight.lua
-- xvi Syntax Highlight Engine
--
-- Language files: /lib/vi/lang_<ext>.lua
-- Format:
--   return {
--     name         = "Lua",
--     lineComment  = "--",
--     blockComment = {"--[[", "]]"},    -- or nil
--     operators    = "+-*/%=<>~#.;,",
--     keywords     = { ["if"]=1, ["end"]=1, ... },
--     builtins     = { ["print"]=2, ["nil"]=2, ... },
--   }
-- Category 1 = keyword (blue), 2 = builtin (cyan)
--

local H = {}

-- Palette
H.C_DEFAULT  = 0xFFFFFF
H.C_KEYWORD  = 0x5599FF
H.C_BUILTIN  = 0x55DDDD
H.C_STRING   = 0xDD9955
H.C_NUMBER   = 0x99DD77
H.C_COMMENT  = 0x777777
H.C_OPERATOR = 0xAAAAAA

local tCatColor = {
  [1] = H.C_KEYWORD,
  [2] = H.C_BUILTIN,
}

-- Universal (no lang file needed)
H.UNIVERSAL = {
  name = "Text",
  lineComment  = nil,
  blockComment = nil,
  operators    = "+-*/%=<>!&|^~?:;,.{}()[]#@",
  keywords     = {},
  builtins     = {},
}

local tLangCache = {}

function H.detect(sPath)
  if not sPath then return H.UNIVERSAL end
  local sExt = sPath:match("%.([^%.]+)$")
  if not sExt then return H.UNIVERSAL end
  sExt = sExt:lower()
  -- cfg files are usually Lua tables
  if sExt == "cfg" then sExt = "lua" end
  if tLangCache[sExt] then return tLangCache[sExt] end
  local bOk, tLang = pcall(require, "vi/lang_" .. sExt)
  if bOk and type(tLang) == "table" then
    tLangCache[sExt] = tLang
    return tLang
  end
  tLangCache[sExt] = H.UNIVERSAL
  return H.UNIVERSAL
end

-- =============================================
-- BLOCK COMMENT STATE
-- Returns tState[n] = true if line n starts
-- inside a block comment.
-- =============================================

function H.computeState(tLines, tLang)
  local tState = {}
  if not tLang or not tLang.blockComment then
    for i = 1, #tLines do tState[i] = false end
    return tState
  end

  local sBS = tLang.blockComment[1]
  local sBE = tLang.blockComment[2]
  local sLC = tLang.lineComment
  local bIn = false

  for i = 1, #tLines do
    tState[i] = bIn
    local s = tLines[i]
    local p = 1
    while p <= #s do
      if bIn then
        local e = s:find(sBE, p, true)
        if e then bIn = false; p = e + #sBE
        else break end
      else
        if sBS and p + #sBS - 1 <= #s and s:sub(p, p + #sBS - 1) == sBS then
          bIn = true; p = p + #sBS
        elseif sLC and p + #sLC - 1 <= #s and s:sub(p, p + #sLC - 1) == sLC then
          break
        elseif s:sub(p, p) == '"' or s:sub(p, p) == "'" then
          local q = s:sub(p, p); p = p + 1
          while p <= #s do
            if s:sub(p, p) == '\\' then p = p + 2
            elseif s:sub(p, p) == q then p = p + 1; break
            else p = p + 1 end
          end
        else
          p = p + 1
        end
      end
    end
  end
  return tState
end

-- =============================================
-- HELPERS
-- =============================================

local function isId(b)
  return (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
      or (b >= 48 and b <= 57) or b == 95
end

local function isDig(b) return b >= 48 and b <= 57 end

local function isHex(b)
  return isDig(b) or (b >= 65 and b <= 70) or (b >= 97 and b <= 102)
end

-- =============================================
-- PER-CHARACTER COLORIZE
-- Returns array: tColors[charIndex] = fg_color
-- =============================================

function H.colorize(sLine, tLang, bInBlock)
  local nLen = #sLine
  if nLen == 0 then return {} end

  local tC = {}
  for i = 1, nLen do tC[i] = H.C_DEFAULT end

  local sBS = tLang.blockComment and tLang.blockComment[1]
  local sBE = tLang.blockComment and tLang.blockComment[2]
  local sLC = tLang.lineComment
  local tKW = tLang.keywords or {}
  local tBI = tLang.builtins or {}
  local sOp = tLang.operators or ""
  local p = 1

  local function paint(nFrom, nTo, nColor)
    for i = nFrom, math.min(nTo, nLen) do tC[i] = nColor end
  end

  -- Start inside block comment?
  if bInBlock then
    if sBE then
      local e = sLine:find(sBE, 1, true)
      if e then
        paint(1, e + #sBE - 1, H.C_COMMENT)
        p = e + #sBE
      else
        paint(1, nLen, H.C_COMMENT)
        return tC
      end
    else
      paint(1, nLen, H.C_COMMENT)
      return tC
    end
  end

  while p <= nLen do
    local c = sLine:sub(p, p)
    local b = c:byte()

    -- Block comment start
    if sBS and p + #sBS - 1 <= nLen and sLine:sub(p, p + #sBS - 1) == sBS then
      local nStart = p
      if sBE then
        local e = sLine:find(sBE, p + #sBS, true)
        if e then
          paint(nStart, e + #sBE - 1, H.C_COMMENT)
          p = e + #sBE
        else
          paint(nStart, nLen, H.C_COMMENT)
          p = nLen + 1
        end
      else
        paint(nStart, nLen, H.C_COMMENT)
        p = nLen + 1
      end

    -- Line comment
    elseif sLC and p + #sLC - 1 <= nLen and sLine:sub(p, p + #sLC - 1) == sLC then
      paint(p, nLen, H.C_COMMENT)
      p = nLen + 1

    -- Strings
    elseif c == '"' or c == "'" then
      local nStart = p
      local q = c; p = p + 1
      while p <= nLen do
        if sLine:sub(p, p) == '\\' then p = p + 2
        elseif sLine:sub(p, p) == q then p = p + 1; break
        else p = p + 1 end
      end
      paint(nStart, p - 1, H.C_STRING)

    -- Long strings [[ ]], [=[ ]=]
    elseif c == '[' and p < nLen then
      local nEq = 0
      local nProbe = p + 1
      while nProbe <= nLen and sLine:sub(nProbe, nProbe) == '=' do
        nEq = nEq + 1; nProbe = nProbe + 1
      end
      if nProbe <= nLen and sLine:sub(nProbe, nProbe) == '[' then
        local nStart = p
        local sClose = ']' .. string.rep('=', nEq) .. ']'
        local e = sLine:find(sClose, nProbe + 1, true)
        if e then
          paint(nStart, e + #sClose - 1, H.C_STRING)
          p = e + #sClose
        else
          paint(nStart, nLen, H.C_STRING)
          p = nLen + 1
        end
      else
        tC[p] = H.C_OPERATOR; p = p + 1
      end

    -- Numbers
    elseif isDig(b) or (c == '.' and p < nLen and isDig(sLine:byte(p + 1))) then
      local nStart = p
      if c == '0' and p < nLen and (sLine:sub(p+1,p+1) == 'x' or sLine:sub(p+1,p+1) == 'X') then
        p = p + 2
        while p <= nLen and isHex(sLine:byte(p)) do p = p + 1 end
      else
        while p <= nLen and (isDig(sLine:byte(p)) or sLine:sub(p,p) == '.') do p = p + 1 end
        if p <= nLen and (sLine:sub(p,p) == 'e' or sLine:sub(p,p) == 'E') then
          p = p + 1
          if p <= nLen and (sLine:sub(p,p) == '+' or sLine:sub(p,p) == '-') then p = p + 1 end
          while p <= nLen and isDig(sLine:byte(p)) do p = p + 1 end
        end
      end
      paint(nStart, p - 1, H.C_NUMBER)

    -- Identifiers
    elseif isId(b) and not isDig(b) then
      local nStart = p
      while p <= nLen and isId(sLine:byte(p)) do p = p + 1 end
      local sWord = sLine:sub(nStart, p - 1)
      local nCat = tKW[sWord] or tBI[sWord]
      if nCat then paint(nStart, p - 1, tCatColor[nCat] or H.C_KEYWORD) end

    -- Operators
    elseif sOp:find(c, 1, true) then
      tC[p] = H.C_OPERATOR; p = p + 1

    else
      p = p + 1
    end
  end

  return tC
end

-- =============================================
-- VISIBLE SEGMENTS
-- Takes a full line, returns {text, fg, bg}
-- segments for the visible [nLeft..nLeft+nW-1] range.
-- Groups same-color runs.
-- =============================================

function H.segments(sLine, nLeft, nW, tLang, bInBlock)
  local tColors = H.colorize(sLine, tLang, bInBlock)
  local tOut = {}
  local nEnd = math.min(nLeft + nW - 1, #sLine)

  if nLeft > #sLine then
    return {{string.rep(" ", nW), H.C_DEFAULT, 0x000000}}
  end

  local nRun = nLeft
  while nRun <= nEnd do
    local nC = tColors[nRun] or H.C_DEFAULT
    local nRunEnd = nRun
    while nRunEnd < nEnd and (tColors[nRunEnd + 1] or H.C_DEFAULT) == nC do
      nRunEnd = nRunEnd + 1
    end
    tOut[#tOut + 1] = {sLine:sub(nRun, nRunEnd), nC, 0x000000}
    nRun = nRunEnd + 1
  end

  local nUsed = nEnd - nLeft + 1
  if nUsed < nW then
    tOut[#tOut + 1] = {string.rep(" ", nW - nUsed), H.C_DEFAULT, 0x000000}
  end

  return tOut
end

return H