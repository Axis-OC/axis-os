--
-- /usr/commands/regedit.lua
-- AxisOS Registry Editor v3
-- Alt-screen, batch-rendered, memory-lean.
--
-- Controls:
--   Up/Down      Navigate
--   Right/Enter  Expand node / enter values
--   Left         Collapse / go to parent / back to tree
--   Tab          Switch panel (Tree <-> Values)
--   /            Search (type term, Enter applies, Esc cancels)
--   R / F5       Refresh (clears search)
--   Q / Ctrl+C   Quit
--   PgUp/PgDn   Page scroll
--   Home/End     Jump top/bottom
--

local fs = require("filesystem")

local hIn  = fs.open("/dev/tty", "r")
local hOut = fs.open("/dev/tty", "w")
if not hIn or not hOut then print("regedit: no tty"); return end

fs.deviceControl(hIn, "set_mode", {"raw"})
local bSz, tSz = fs.deviceControl(hIn, "get_size", {})
local W = (bSz and tSz and tSz.w) or 80
local H = (bSz and tSz and tSz.h) or 25

-- =============================================
-- PALETTE & LAYOUT
-- =============================================

local FG      = 0xFFFFFF
local BG      = 0x000000
local SEL     = 0xFFFF00
local DIM     = 0x555555
local KEY_C   = 0x5599FF
local STR_C   = 0x55DD55
local NUM_C   = 0xFFFF55
local BOOL_C  = 0xFF55FF
local HDR_C   = 0x55FFFF
local BAR_FG  = 0xFFFFFF
local BAR_BG  = 0x0000AA

local TW = math.max(20, math.floor(W * 0.38))
local VX = TW + 2
local VW = math.max(10, W - VX + 1)
local BY = 3
local BH = H - 4

-- Value column widths
local CN = 20
local CT = 6
local CV = math.max(1, VW - CN - CT)

-- =============================================
-- STATE
-- =============================================

local tExp     = { ["@VT"] = true }
local nTSel    = 1
local nTTop    = 0
local nVSel    = 1
local nVTop    = 0
local bTFocus  = true
local bRun     = true
local sMsg     = ""
local sSearch  = nil

local bSearchMode = false
local sSearchBuf  = ""

-- Tree: entries are {depth, name, path, hasKids, expanded}
local tTree = {}
local nTree = 0

-- Values for selected node
local tVals = {}
local nVals = 0

-- =============================================
-- BATCH RENDERER (reuses tables across frames)
-- =============================================

local tBatch = {}
local nBatch = 0

local function bp(x, y, s, fg, bg)
  nBatch = nBatch + 1
  local e = tBatch[nBatch]
  if e then
    e[1] = x; e[2] = y; e[3] = s
    e[4] = fg or FG; e[5] = bg or BG
  else
    tBatch[nBatch] = { x, y, s, fg or FG, bg or BG }
  end
end

local function bFlush()
  if nBatch > 0 then
    for i = nBatch + 1, #tBatch do tBatch[i] = nil end
    fs.deviceControl(hIn, "render_batch", tBatch)
    nBatch = 0
  end
end

local function gFill(x, y, w, h, fg, bg)
  fs.deviceControl(hIn, "gpu_fill", { x, y, w, h, " ", fg or FG, bg or BG })
end

local function pad(s, n)
  local len = #s
  if len >= n then return s:sub(1, n) end
  return s .. string.rep(" ", n - len)
end

-- =============================================
-- DATA: TREE
-- =============================================

local function buildTree()
  for i = 1, #tTree do tTree[i] = nil end
  nTree = 0

  local function walk(sPath, depth)
    local tKeys = syscall("reg_enum_keys", sPath)
    if not tKeys then return end
    for _, sKey in ipairs(tKeys) do
      local sChild = sPath .. "\\" .. sKey

      if sSearch and not sChild:lower():find(sSearch, 1, true) then
        goto skip
      end

      local tI = syscall("reg_query_info", sChild)
      local bHas = tI and tI.nSubKeys > 0
      local bEx  = tExp[sChild] or false
      nTree = nTree + 1
      tTree[nTree] = { depth, sKey, sChild, bHas, bEx }
      if bEx and bHas then walk(sChild, depth + 1) end
      ::skip::
    end
  end

  local tRK = syscall("reg_enum_keys", "@VT") or {}
  nTree = 1
  tTree[1] = { 0, "@VT", "@VT", #tRK > 0, true }
  walk("@VT", 1)

  if nTSel > nTree then nTSel = nTree end
  if nTSel < 1 then nTSel = 1 end
end

-- =============================================
-- DATA: VALUES
-- =============================================

local function loadVals()
  for i = 1, #tVals do tVals[i] = nil end
  nVals = 0; nVSel = 1; nVTop = 0
  if nTSel >= 1 and nTSel <= nTree then
    local tv = syscall("reg_enum_values", tTree[nTSel][3])
    if tv then
      for i = 1, #tv do tVals[i] = tv[i] end
      nVals = #tv
    end
  end
end

-- =============================================
-- SCROLL
-- =============================================

local function treeVis()
  if nTSel < nTTop + 1 then nTTop = nTSel - 1 end
  if nTSel > nTTop + BH then nTTop = nTSel - BH end
  if nTTop < 0 then nTTop = 0 end
end

local function valVis()
  local dh = math.max(1, BH - 2)
  if nVSel < nVTop + 1 then nVTop = nVSel - 1 end
  if nVSel > nVTop + dh then nVTop = nVSel - dh end
  if nVTop < 0 then nVTop = 0 end
end

-- =============================================
-- RENDER
-- =============================================

local function render()
  treeVis(); valVis()

  -- Header
  local sPanel  = bTFocus and "[Tree]" or "[Values]"
  local sFilter = sSearch and (" /" .. sSearch) or ""
  bp(1, 1, pad(" Registry " .. sPanel .. sFilter, W), BAR_FG, BAR_BG)

  -- Path
  local sPath = (nTSel >= 1 and nTSel <= nTree) and tTree[nTSel][3] or "@VT"
  if #sPath > W - 4 then sPath = ".." .. sPath:sub(-(W - 6)) end
  bp(1, 2, pad(" " .. sPath, W), HDR_C, BG)

  -- Tree rows
  for row = 1, BH do
    local y   = BY + row - 1
    local idx = row + nTTop

    if idx >= 1 and idx <= nTree then
      local t  = tTree[idx]
      local sI = string.rep(" ", t[1] * 2)
      local sC = t[4] and (t[5] and "v" or ">") or "-"
      local sN = t[2]
      local nM = TW - #sI - 3
      if nM < 1 then nM = 1 end
      if #sN > nM then sN = sN:sub(1, math.max(1, nM - 2)) .. ".." end
      local fg = (idx == nTSel) and (bTFocus and SEL or DIM) or KEY_C
      bp(1, y, pad(sI .. sC .. " " .. sN, TW), fg, BG)
    else
      bp(1, y, pad("", TW), FG, BG)
    end

    -- Divider
    bp(TW + 1, y, "|", DIM, BG)
  end

  -- Value header + separator
  bp(VX, BY,     pad(pad("Name", CN) .. pad("Type", CT) .. "Value", VW), DIM, BG)
  bp(VX, BY + 1, pad(string.rep("-", math.min(VW, 60)), VW), DIM, BG)

  -- Value rows
  local dh = math.max(1, BH - 2)
  for i = 1, dh do
    local y   = BY + 1 + i
    local idx = i + nVTop

    if idx >= 1 and idx <= nVals then
      local v  = tVals[idx]
      local sN = v.sName or "?"
      if #sN > CN - 1 then sN = sN:sub(1, CN - 3) .. ".." end
      local sT = v.sType or "?"
      local sV = tostring(v.value or "")
      if type(v.value) == "table" then sV = "{..}" end
      if #sV > CV then sV = sV:sub(1, math.max(1, CV - 2)) .. ".." end

      local bS = (idx == nVSel) and not bTFocus
      local fN = bS and SEL or FG
      local fT = bS and SEL
                 or (sT == "NUM" and NUM_C or (sT == "BOOL" and BOOL_C or STR_C))

      bp(VX,           y, pad(sN, CN), fN, BG)
      bp(VX + CN,      y, pad(sT, CT), fT, BG)
      bp(VX + CN + CT, y, pad(sV, CV), fN, BG)
    else
      bp(VX, y, pad("", VW), FG, BG)
    end
  end

  -- Status
  bp(1, H - 1, pad(string.rep("-", W), W), DIM, BG)

  if bSearchMode then
    bp(1, H, pad(" /" .. sSearchBuf .. "_", W), SEL, BAR_BG)
  elseif #sMsg > 0 then
    bp(1, H, pad(" " .. sMsg, W), SEL, BAR_BG)
    sMsg = ""
  else
    local sL = " Arrows:Nav Tab:Panel /:Find R:Refresh Q:Quit"
    local sR = string.format(" %d/%d ", nTSel, nTree)
    local nP = math.max(0, W - #sL - #sR)
    bp(1, H, pad(sL .. string.rep(" ", nP) .. sR, W), BAR_FG, BAR_BG)
  end

  bFlush()
end

-- =============================================
-- INPUT: SEARCH MODE
-- =============================================

local function handleSearch(k)
  if k == "\27" then
    bSearchMode = false; sSearchBuf = ""
    return
  end
  if k == "\n" then
    bSearchMode = false
    sSearch = (#sSearchBuf > 0) and sSearchBuf:lower() or nil
    sSearchBuf = ""
    buildTree(); nTSel = 1; nTTop = 0; loadVals()
    return
  end
  if k == "\b" then
    if #sSearchBuf > 0 then sSearchBuf = sSearchBuf:sub(1, -2)
    else bSearchMode = false end
    return
  end
  if #k == 1 and k:byte() >= 32 and k:byte() < 127 then
    sSearchBuf = sSearchBuf .. k
  end
end

-- =============================================
-- INPUT: NORMAL MODE
-- =============================================

local function handleNormal(k)
  if k == "\3" or k == "q" or k == "Q" then bRun = false; return end
  if k == "\t" then bTFocus = not bTFocus; return end

  if k == "/" then bSearchMode = true; sSearchBuf = ""; return end

  if k == "r" or k == "R" or k == "\27[15~" then
    sSearch = nil; buildTree(); loadVals(); sMsg = "Refreshed"; return
  end

  if bTFocus then
    -- ---- TREE NAVIGATION ----
    if k == "\27[A" then                               -- Up
      nTSel = math.max(1, nTSel - 1); loadVals()

    elseif k == "\27[B" then                           -- Down
      nTSel = math.min(nTree, nTSel + 1); loadVals()

    elseif k == "\27[C" or k == "\n" then              -- Right / Enter
      if nTSel >= 1 and nTSel <= nTree then
        local t = tTree[nTSel]
        if t[4] and not t[5] then                      -- has kids, collapsed
          tExp[t[3]] = true; buildTree(); loadVals()
        elseif not t[4] then                           -- leaf → jump to values
          bTFocus = false
        end
      end

    elseif k == "\27[D" then                           -- Left
      if nTSel >= 1 and nTSel <= nTree then
        local t = tTree[nTSel]
        if t[5] then                                   -- expanded → collapse
          tExp[t[3]] = nil; buildTree(); loadVals()
        elseif nTSel > 1 then                          -- go to parent
          local d = t[1]
          for i = nTSel - 1, 1, -1 do
            if tTree[i][1] < d then
              nTSel = i; loadVals(); break
            end
          end
        end
      end

    elseif k == "\27[5~" then                          -- PgUp
      nTSel = math.max(1, nTSel - BH); loadVals()
    elseif k == "\27[6~" then                          -- PgDn
      nTSel = math.min(nTree, nTSel + BH); loadVals()
    elseif k == "\27[H" then                           -- Home
      nTSel = 1; nTTop = 0; loadVals()
    elseif k == "\27[F" then                           -- End
      nTSel = nTree; loadVals()
    end

  else
    -- ---- VALUE NAVIGATION ----
    if k == "\27[A" then
      nVSel = math.max(1, nVSel - 1)
    elseif k == "\27[B" then
      nVSel = math.min(nVals, nVSel + 1)
    elseif k == "\27[D" then                           -- Left → back to tree
      bTFocus = true
    elseif k == "\27[5~" then
      nVSel = math.max(1, nVSel - math.max(1, BH - 2))
    elseif k == "\27[6~" then
      nVSel = math.min(nVals, nVSel + math.max(1, BH - 2))
    end
  end
end

-- =============================================
-- MAIN
-- =============================================

local function main()
  fs.deviceControl(hIn, "enter_alt_screen", {})
  buildTree()
  loadVals()

  while bRun do
    render()
    local k = fs.read(hIn)
    if not k then bRun = false
    elseif bSearchMode then handleSearch(k)
    else handleNormal(k) end
  end
end

local ok, err = pcall(main)
fs.deviceControl(hIn, "leave_alt_screen", {})
fs.deviceControl(hIn, "set_mode", {"cooked"})
fs.close(hIn)
fs.close(hOut)
if not ok then print("regedit: " .. tostring(err)) end