--
-- /usr/commands/regedit.lua
-- AxisOS Visual Registry Editor v2
-- Batched rendering — single write per frame.
--
-- Controls:
--   Up/Down      Navigate
--   Right/Enter  Expand node
--   Left         Collapse / go to parent
--   Tab          Switch panel (Tree <-> Values)
--   R            Refresh
--   Q/Ctrl+C     Quit
--   /            Search (type then Enter)
--   F5           Force full refresh
--

local fs  = require("filesystem")
local sys = require("syscall")

-- =============================================
-- TERMINAL SETUP
-- =============================================

local hStdin  = fs.open("/dev/tty", "r")
local hStdout = fs.open("/dev/tty", "w")
if not hStdin or not hStdout then print("regedit: cannot open /dev/tty"); return end

local nWidth, nHeight = 80, 25
local bOkSize, tSize = fs.deviceControl(hStdin, "get_size", {})
if bOkSize and type(tSize) == "table" then
  nWidth  = tSize.w or 80
  nHeight = tSize.h or 25
end

fs.deviceControl(hStdin, "set_mode", {"raw"})

local function cleanup()
  fs.deviceControl(hStdin, "set_mode", {"cooked"})
  fs.write(hStdout, "\27[0m\27[2J\27[1;1H")
  fs.flush(hStdout)
  fs.close(hStdin)
  fs.close(hStdout)
end

-- =============================================
-- FRAME BUFFER
-- All rendering goes into this table.
-- One concat + one write at the end of each frame.
-- =============================================

local tFrameBuf = {}
local nFrameParts = 0

local function fbReset()
  tFrameBuf = {}
  nFrameParts = 0
end

local function fb(s)
  nFrameParts = nFrameParts + 1
  tFrameBuf[nFrameParts] = s
end

local function fbCursor(x, y)
  nFrameParts = nFrameParts + 1
  tFrameBuf[nFrameParts] = "\27[" .. y .. ";" .. x .. "H"
end

local function fbFlush()
  local sFrame = table.concat(tFrameBuf)
  fs.write(hStdout, sFrame)
  fs.flush(hStdout)
  fbReset()
end

-- =============================================
-- INPUT (non-blocking-ish via raw mode)
-- =============================================

local function readKey()
  return fs.read(hStdin)
end

-- =============================================
-- ANSI CONSTANTS
-- =============================================

local A = {
  RESET   = "\27[0m",
  R       = "\27[37m",
  RED     = "\27[31m",
  GRN     = "\27[32m",
  YLW     = "\27[33m",
  BLU     = "\27[34m",
  MAG     = "\27[35m",
  CYN     = "\27[36m",
  GRY     = "\27[90m",
  INV     = "\27[7m",
  NINV    = "\27[27m",
  CLR     = "\27[2J",
  HOME    = "\27[1;1H",
}

-- =============================================
-- STRING HELPERS
-- =============================================

local function padRight(s, n)
  local sLen = #s
  if sLen >= n then return s:sub(1, n) end
  return s .. string.rep(" ", n - sLen)
end

-- strip ANSI for length calculation
local function visLen(s)
  return #(s:gsub("\27%[[%d;]*[a-zA-Z]", ""))
end

-- pad a string that may contain ANSI codes
local function padRightAnsi(s, n)
  local nVis = visLen(s)
  if nVis >= n then return s end
  return s .. string.rep(" ", n - nVis)
end

-- =============================================
-- STATE
-- =============================================

local tExpanded   = { ["@VT"] = true }
local nTreeSel    = 1
local nTreeScroll = 0
local nValSel     = 1
local nValScroll  = 0
local bTreeFocus  = true
local bRunning    = true
local sSearchTerm = nil

-- =============================================
-- LAYOUT
-- =============================================

local HEADER_H = 2
local STATUS_H = 2
local TREE_W   = math.floor(nWidth * 0.38)
if TREE_W < 22 then TREE_W = 22 end
local VAL_X    = TREE_W + 2
local VAL_W    = nWidth - VAL_X + 1
if VAL_W < 20 then VAL_W = 20 end
local BODY_TOP = HEADER_H + 1
local BODY_H   = nHeight - HEADER_H - STATUS_H
local BODY_BOT = BODY_TOP + BODY_H - 1

-- =============================================
-- DATA MODEL
-- =============================================

local tVisibleTree   = {}
local tCurrentValues = {}

local function buildTree()
  tVisibleTree = {}

  local function walk(sPath, nDepth)
    local tKeys = syscall("reg_enum_keys", sPath)
    if not tKeys then return end
    for _, sKey in ipairs(tKeys) do
      local sChild = sPath .. "\\" .. sKey
      local tChildKeys = syscall("reg_enum_keys", sChild)
      local bHas = tChildKeys and #tChildKeys > 0
      local bExp = tExpanded[sChild] or false

      -- search filter
      local bShow = true
      if sSearchTerm then
        local sLower = sChild:lower()
        if not sLower:find(sSearchTerm, 1, true) then
          -- check if any descendant matches
          local tDesc = syscall("reg_dump_tree", sChild, 5)
          bShow = false
          if tDesc then
            for _, tN in ipairs(tDesc) do
              if tN.sPath:lower():find(sSearchTerm, 1, true) then
                bShow = true; break
              end
            end
          end
        end
      end

      if bShow then
        table.insert(tVisibleTree, {
          nDepth       = nDepth,
          sName        = sKey,
          sPath        = sChild,
          bExpanded    = bExp,
          bHasChildren = bHas,
        })
        if bExp then walk(sChild, nDepth + 1) end
      end
    end
  end

  local tRootKeys = syscall("reg_enum_keys", "@VT")
  table.insert(tVisibleTree, {
    nDepth       = 0,
    sName        = "@VT",
    sPath        = "@VT",
    bExpanded    = true,
    bHasChildren = tRootKeys and #tRootKeys > 0,
  })
  walk("@VT", 1)
end

local function loadValues()
  tCurrentValues = {}
  nValSel = 1
  nValScroll = 0
  if nTreeSel < 1 or nTreeSel > #tVisibleTree then return end
  local sPath = tVisibleTree[nTreeSel].sPath
  local tVals = syscall("reg_enum_values", sPath)
  if tVals then tCurrentValues = tVals end
end

-- =============================================
-- RENDERING (all into frame buffer)
-- =============================================

local function renderHeader()
  fbCursor(1, 1)
  fb(A.INV)
  local sTitle = "  AxisOS Registry Editor"
  local sPanel = bTreeFocus and " [Tree] " or " [Values] "
  local sSearch = sSearchTerm and (" Filter: " .. sSearchTerm .. " ") or ""
  local sLine = sTitle .. sPanel .. sSearch
  fb(padRight(sLine, nWidth))
  fb(A.NINV .. A.R)

  fbCursor(1, 2)
  local sPath = ""
  if nTreeSel >= 1 and nTreeSel <= #tVisibleTree then
    sPath = tVisibleTree[nTreeSel].sPath
  end
  local sInfo = ""
  if nTreeSel >= 1 and nTreeSel <= #tVisibleTree then
    local tI = syscall("reg_query_info", tVisibleTree[nTreeSel].sPath)
    if tI then
      sInfo = A.GRY .. " [" .. tI.nSubKeys .. " keys, " .. tI.nValues .. " vals]" .. A.R
    end
  end
  local sPathLine = A.GRY .. " " .. A.CYN .. sPath .. sInfo
  fb(padRightAnsi(sPathLine, nWidth))
end

local function renderTree()
  for screenRow = 1, BODY_H do
    local screenY = BODY_TOP + screenRow - 1
    fbCursor(1, screenY)

    local nIdx = screenRow + nTreeScroll
    if nIdx >= 1 and nIdx <= #tVisibleTree then
      local tNode = tVisibleTree[nIdx]
      local bSel = (nIdx == nTreeSel)

      -- build the line
      local sIndent = string.rep("  ", tNode.nDepth)
      local sIcon
      if not tNode.bHasChildren then
        sIcon = "-"
      elseif tNode.bExpanded then
        sIcon = "v"
      else
        sIcon = ">"
      end

      local sLabel = tNode.sName
      local nMax = TREE_W - #sIndent - 3
      if nMax < 4 then nMax = 4 end
      if #sLabel > nMax then sLabel = sLabel:sub(1, nMax - 2) .. ".." end

      -- colorize
      if bSel and bTreeFocus then
        -- selected + focused: yellow inverse-ish
        fb(A.YLW)
        fb(padRight(sIndent .. sIcon .. " " .. sLabel, TREE_W))
        fb(A.R)
      elseif bSel then
        -- selected but not focused: gray highlight
        fb(A.GRY)
        fb(padRight(sIndent .. sIcon .. " " .. sLabel, TREE_W))
        fb(A.R)
      else
        -- normal: icon gray, name blue
        fb(A.GRY .. sIndent .. sIcon .. " " .. A.BLU .. sLabel .. A.R)
        -- pad remainder
        local nUsed = #sIndent + 2 + #sLabel
        if nUsed < TREE_W then
          fb(string.rep(" ", TREE_W - nUsed))
        end
      end
    else
      fb(string.rep(" ", TREE_W))
    end
  end
end

local function renderDivider()
  for screenRow = 1, BODY_H do
    fbCursor(TREE_W + 1, BODY_TOP + screenRow - 1)
    fb(A.GRY .. "|" .. A.R)
  end
end

local function typeColor(sType)
  if sType == "NUM" then return A.YLW
  elseif sType == "BOOL" then return A.MAG
  elseif sType == "TAB" then return A.CYN
  else return A.GRN end
end

local function renderValues()
  -- column header
  fbCursor(VAL_X, BODY_TOP)
  local sHdr = A.GRY
  local sN = "Name"
  local sT = "Type"
  local sV = "Value"
  -- fixed column widths
  local COL_NAME = 22
  local COL_TYPE = 6
  local COL_VAL  = VAL_W - COL_NAME - COL_TYPE - 2

  sHdr = sHdr .. padRight(sN, COL_NAME) .. padRight(sT, COL_TYPE) .. sV
  fb(padRight(sHdr, VAL_W) .. A.R)

  fbCursor(VAL_X, BODY_TOP + 1)
  fb(A.GRY .. string.rep("-", VAL_W) .. A.R)

  local nDataTop = BODY_TOP + 2
  local nDataH   = BODY_BOT - nDataTop + 1
  if nDataH < 1 then nDataH = 1 end

  for i = 1, nDataH do
    local screenY = nDataTop + i - 1
    fbCursor(VAL_X, screenY)

    local nIdx = i + nValScroll
    if nIdx >= 1 and nIdx <= #tCurrentValues then
      local tVal = tCurrentValues[nIdx]
      local bSel = (nIdx == nValSel) and not bTreeFocus

      local sName = tVal.sName or "?"
      if #sName > COL_NAME - 1 then sName = sName:sub(1, COL_NAME - 4) .. "..." end

      local sType = tVal.sType or "?"
      local sTC   = typeColor(sType)

      local sValue = tostring(tVal.value or "")
      if type(tVal.value) == "table" then sValue = "{...}" end
      if COL_VAL > 0 and #sValue > COL_VAL then
        sValue = sValue:sub(1, COL_VAL - 3) .. "..."
      end

      if bSel then
        fb(A.YLW)
        fb(padRight(sName, COL_NAME))
        fb(padRight(sType, COL_TYPE))
        fb(padRight(sValue, math.max(0, COL_VAL)))
        fb(A.R)
      else
        fb(padRight(sName, COL_NAME))
        fb(sTC .. padRight(sType, COL_TYPE) .. A.R)
        fb(padRight(sValue, math.max(0, COL_VAL)))
      end
    else
      fb(string.rep(" ", VAL_W))
    end
  end
end

local function renderStatus()
  fbCursor(1, nHeight - 1)
  fb(A.GRY .. string.rep("-", nWidth) .. A.R)

  fbCursor(1, nHeight)
  fb(A.INV)

  local sHelp = " Up/Dn:Move L/R:Expand Tab:Panel /:Search R:Refresh Q:Quit"
  local sInfo = string.format(" %d/%d keys  %d vals ",
        nTreeSel, #tVisibleTree, #tCurrentValues)

  local nPad = nWidth - #sHelp - #sInfo
  if nPad < 0 then nPad = 0 end
  fb(sHelp .. string.rep(" ", nPad) .. sInfo)
  fb(A.NINV .. A.R)
end

local function render()
  fbReset()
  fb(A.RESET .. A.CLR .. A.HOME)
  renderHeader()
  renderTree()
  renderDivider()
  renderValues()
  renderStatus()
  fbFlush()
end

-- =============================================
-- SCROLL HELPERS
-- =============================================

local function ensureTreeVisible()
  if nTreeSel < nTreeScroll + 1 then
    nTreeScroll = nTreeSel - 1
  end
  if nTreeSel > nTreeScroll + BODY_H then
    nTreeScroll = nTreeSel - BODY_H
  end
  if nTreeScroll < 0 then nTreeScroll = 0 end
end

local function ensureValVisible()
  local nDataH = math.max(1, BODY_H - 2)
  if nValSel < nValScroll + 1 then
    nValScroll = nValSel - 1
  end
  if nValSel > nValScroll + nDataH then
    nValScroll = nValSel - nDataH
  end
  if nValScroll < 0 then nValScroll = 0 end
end

-- =============================================
-- SEARCH
-- =============================================

local function doSearch()
  -- show a prompt on the status bar
  fbReset()
  fbCursor(1, nHeight)
  fb(A.INV .. padRight(" Search: ", nWidth) .. A.NINV .. A.R)
  fbCursor(10, nHeight)
  fbFlush()

  -- switch back to cooked mode for line input
  fs.deviceControl(hStdin, "set_mode", {"cooked"})
  fs.deviceControl(hStdin, "set_buffer", {""})

  local sInput = fs.read(hStdin)

  -- back to raw mode
  fs.deviceControl(hStdin, "set_mode", {"raw"})

  if sInput then
    sInput = sInput:gsub("\n", ""):gsub("\r", "")
    if #sInput > 0 then
      sSearchTerm = sInput:lower()
    else
      sSearchTerm = nil
    end
  else
    sSearchTerm = nil
  end

  buildTree()
  nTreeSel = 1
  nTreeScroll = 0
  loadValues()
end

-- =============================================
-- INPUT
-- =============================================

local function handleInput(sKey)
  if not sKey then return end

  if sKey == "\3" or sKey == "q" or sKey == "Q" then
    bRunning = false; return
  end

  if sKey == "\t" then
    bTreeFocus = not bTreeFocus; return
  end

  if sKey == "r" or sKey == "R" or sKey == "\27[15~" then -- R or F5
    sSearchTerm = nil
    buildTree()
    if nTreeSel > #tVisibleTree then nTreeSel = #tVisibleTree end
    if nTreeSel < 1 then nTreeSel = 1 end
    loadValues()
    return
  end

  if sKey == "/" then
    doSearch(); return
  end

  if bTreeFocus then
    -- === TREE ===
    if sKey == "\27[A" then -- Up
      nTreeSel = math.max(1, nTreeSel - 1)
      ensureTreeVisible(); loadValues()

    elseif sKey == "\27[B" then -- Down
      nTreeSel = math.min(#tVisibleTree, nTreeSel + 1)
      ensureTreeVisible(); loadValues()

    elseif sKey == "\27[C" or sKey == "\n" then -- Right / Enter
      if nTreeSel >= 1 and nTreeSel <= #tVisibleTree then
        local tN = tVisibleTree[nTreeSel]
        if tN.bHasChildren and not tN.bExpanded then
          tExpanded[tN.sPath] = true
          buildTree(); loadValues()
        elseif not tN.bHasChildren then
          -- leaf: switch to values panel
          bTreeFocus = false
        end
      end

    elseif sKey == "\27[D" then -- Left
      if nTreeSel >= 1 and nTreeSel <= #tVisibleTree then
        local tN = tVisibleTree[nTreeSel]
        if tN.bExpanded then
          tExpanded[tN.sPath] = nil
          buildTree(); loadValues()
        elseif nTreeSel > 1 then
          local nD = tN.nDepth
          for i = nTreeSel - 1, 1, -1 do
            if tVisibleTree[i].nDepth < nD then
              nTreeSel = i
              ensureTreeVisible(); loadValues()
              break
            end
          end
        end
      end

    elseif sKey == "\27[5~" then -- PgUp
      nTreeSel = math.max(1, nTreeSel - BODY_H)
      ensureTreeVisible(); loadValues()

    elseif sKey == "\27[6~" then -- PgDn
      nTreeSel = math.min(#tVisibleTree, nTreeSel + BODY_H)
      ensureTreeVisible(); loadValues()

    elseif sKey == "\27[H" then -- Home
      nTreeSel = 1; nTreeScroll = 0; loadValues()

    elseif sKey == "\27[F" then -- End
      nTreeSel = #tVisibleTree; ensureTreeVisible(); loadValues()
    end

  else
    -- === VALUES ===
    if sKey == "\27[A" then
      nValSel = math.max(1, nValSel - 1); ensureValVisible()
    elseif sKey == "\27[B" then
      nValSel = math.min(#tCurrentValues, nValSel + 1); ensureValVisible()
    elseif sKey == "\27[5~" then
      nValSel = math.max(1, nValSel - math.max(1, BODY_H - 2)); ensureValVisible()
    elseif sKey == "\27[6~" then
      nValSel = math.min(#tCurrentValues, nValSel + math.max(1, BODY_H - 2)); ensureValVisible()
    elseif sKey == "\27[D" then -- Left: back to tree
      bTreeFocus = true
    end
  end
end

-- =============================================
-- MAIN
-- =============================================

local function main()
  -- auto-expand top-level hives
  tExpanded["@VT\\DEV"] = true
  tExpanded["@VT\\DRV"] = true
  tExpanded["@VT\\SYS"] = true
  buildTree()
  loadValues()

  while bRunning do
    render()
    local sKey = readKey()
    if sKey then
      handleInput(sKey)
    else
      bRunning = false
    end
  end
end

local bOk, sErr = pcall(main)
cleanup()
if not bOk then
  print("regedit crashed: " .. tostring(sErr))
end