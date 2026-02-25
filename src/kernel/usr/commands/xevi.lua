--
-- /usr/commands/xevi.lua
-- xevi v4 — XE Visual Editor for AxisOS
--
-- Paged buffer (constant memory for huge files).
-- Fuzzy command search, start screen, file tree.
-- Unicode-aware cursor, per-line syntax cache.
-- No collectgarbage (OC does not provide it).
--

local fs = require("filesystem")
local xe = require("xe")

local HL = nil
do
  local ok, mod = pcall(function() return require("vi/highlight") end)
  if ok and type(mod) == "table" then HL = mod end
end

local tArgs = env.ARGS or {}

-- =============================================
-- 1. CONSTANTS & CONFIG
-- =============================================

local PAGE_SZ   = 48
local MAX_CACHE  = 4
local MAX_UNDO   = 8
local SWAP_DIR   = "/tmp/.xevi"
local SCROLL_OFF = 3
local TAB_SIZE   = 2
local TREE_W     = 22

local function loadCfg()
  local c = {lineNumbers=true,tabSize=2,scrollOff=3,autoIndent=true,maxUndo=8}
  pcall(function()
    local h = fs.open("/etc/xevi.cfg","r")
    if h then
      local s = fs.read(h, math.huge); fs.close(h)
      if s then
        local f = load(s,"xevi.cfg","t",{})
        if f then
          local ok,t = pcall(f)
          if ok and type(t)=="table" then
            for k,v in pairs(t) do c[k]=v end
          end
        end
      end
    end
  end)
  return c
end
local cfg = loadCfg()
TAB_SIZE   = cfg.tabSize or 2
SCROLL_OFF = cfg.scrollOff or 3
MAX_UNDO   = cfg.maxUndo or 8

-- =============================================
-- 2. UNICODE HELPERS
-- =============================================

local _uc = unicode
local function ulen(s) return _uc and _uc.len(s) or #s end
local function usub(s,i,j) return _uc and _uc.sub(s,i,j) or s:sub(i,j) end

local function charBytes(s,p)
  local b = s:byte(p)
  if not b or b < 0x80 then return 1
  elseif b < 0xC0 then return 1
  elseif b < 0xE0 then return 2
  elseif b < 0xF0 then return 3
  else return 4 end
end

local function nextCharB(s,p)
  if p > #s then return p+1 end
  return p + charBytes(s,p)
end

local function prevCharB(s,p)
  p = p - 1
  while p > 1 and s:byte(p) >= 0x80 and s:byte(p) < 0xC0 do p = p - 1 end
  return math.max(1,p)
end

-- =============================================
-- 3. PAGED BUFFER
-- =============================================

local buf = {
  meta={}, nPages=0, nTotal=0,
  cache={}, lru={}, nCached=0,
  origPath=nil, sPath=nil,
  offsets={}, swapped={},
  modified=false, tLang=nil,
  tSegCache={}, tLineVer={}, nEditVer=0, tBlkState={}, bStateDirty=true,
}

local function lruTouch(n)
  local L = buf.lru
  for i=#L,1,-1 do if L[i]==n then table.remove(L,i); break end end
  L[#L+1] = n
end
local function lruOldest() return buf.lru[1] end
local function lruRemove(n)
  for i=#buf.lru,1,-1 do if buf.lru[i]==n then table.remove(buf.lru,i); break end end
end

local function swapOut(nP)
  local pg = buf.cache[nP]; if not pg then return end
  if pg.dirty then
    fs.mkdir("/tmp"); fs.mkdir(SWAP_DIR)
    local h = fs.open(SWAP_DIR.."/p"..nP,"w")
    if h then
      for i,s in ipairs(pg.lines) do
        fs.write(h,s); if i<#pg.lines then fs.write(h,"\n") end
      end
      fs.close(h); buf.swapped[nP]=true
    end
  end
  pg.lines=nil; buf.cache[nP]=nil; buf.nCached=buf.nCached-1; lruRemove(nP)
end

local function readSwap(nP)
  local h=fs.open(SWAP_DIR.."/p"..nP,"r")
  if not h then return {""} end
  local tC={}
  while true do local s=fs.read(h,math.huge); if not s then break end; tC[#tC+1]=s end
  fs.close(h)
  local sA=table.concat(tC); tC=nil
  if #sA==0 then return {""} end
  local t={}
  for sL in (sA.."\n"):gmatch("([^\n]*)\n") do t[#t+1]=sL:gsub("\r","") end
  sA=nil
  while #t>(buf.meta[nP] or 1) and #t>1 and t[#t]=="" do t[#t]=nil end
  if #t==0 then t[1]="" end
  return t
end

local function readOrigPage(nP)
  local off=buf.offsets[nP]
  if not off or not buf.origPath then return {""} end
  local h=fs.open(buf.origPath,"r")
  if not h then return {""} end
  local nSkip=off[1]
  while nSkip>0 do
    local s=fs.read(h,math.min(nSkip,4096))
    if not s then fs.close(h); return {""} end
    nSkip=nSkip-#s
  end
  local tC={}; local nRem=off[2]
  while nRem>0 do
    local s=fs.read(h,math.min(nRem,4096))
    if not s then break end; tC[#tC+1]=s; nRem=nRem-#s
  end
  fs.close(h)
  local sA=table.concat(tC); tC=nil
  if #sA==0 then return {""} end
  local t={}
  for sL in (sA.."\n"):gmatch("([^\n]*)\n") do t[#t+1]=sL:gsub("\r","") end
  sA=nil
  while #t>(buf.meta[nP] or 1) and #t>1 and t[#t]=="" do t[#t]=nil end
  if #t==0 then t[1]="" end
  return t
end

local function ensurePage(nP)
  if nP<1 then nP=1 end
  if buf.cache[nP] then lruTouch(nP); return buf.cache[nP] end
  while buf.nCached>=MAX_CACHE do
    local nE=lruOldest(); if nE then swapOut(nE) else break end
  end
  local tL
  if buf.swapped[nP] then tL=readSwap(nP) else tL=readOrigPage(nP) end
  buf.cache[nP]={lines=tL, dirty=buf.swapped[nP] or false}
  buf.nCached=buf.nCached+1; lruTouch(nP)
  return buf.cache[nP]
end

local function lineToPage(nLine)
  local acc=0
  for i=1,buf.nPages do
    local c=buf.meta[i] or 0
    if c>0 and nLine<=acc+c then return i, nLine-acc end
    acc=acc+c
  end
  if buf.nPages==0 then return 1,1 end
  return buf.nPages, buf.meta[buf.nPages] or 1
end

local function getLine(nL)
  if nL<1 or nL>buf.nTotal then return "" end
  local nP,nI=lineToPage(nL)
  return ensurePage(nP).lines[nI] or ""
end

local function setLine(nL, s)
  local nP,nI=lineToPage(nL)
  local pg=ensurePage(nP)
  pg.lines[nI]=s; pg.dirty=true; buf.modified=true
  buf.bStateDirty=true; buf.nEditVer=buf.nEditVer+1
  buf.tLineVer[nL]=buf.nEditVer
end

local function insertLine(nAfter, s)
  local nP,nI
  if nAfter<1 then nP=1; nI=0
  else nP,nI=lineToPage(math.min(nAfter,buf.nTotal)) end
  local pg=ensurePage(nP)
  table.insert(pg.lines, nI+1, s)
  buf.meta[nP]=(buf.meta[nP] or 0)+1
  buf.nTotal=buf.nTotal+1
  pg.dirty=true; buf.modified=true; buf.bStateDirty=true
end

local function deleteLine(nL)
  if buf.nTotal<=1 then setLine(1,""); return end
  local nP,nI=lineToPage(nL)
  local pg=ensurePage(nP)
  table.remove(pg.lines, nI)
  buf.meta[nP]=math.max(0,(buf.meta[nP] or 1)-1)
  buf.nTotal=buf.nTotal-1
  pg.dirty=true; buf.modified=true; buf.bStateDirty=true
end

-- =============================================
-- 4. FILE I/O
-- =============================================

local function openFile(sPath)
  if sPath:sub(1,1)~="/" then sPath=(env.PWD or "/").."/"..sPath end
  sPath=sPath:gsub("//","/")
  local h=fs.open(sPath,"r")
  if not h then return false,"Cannot open: "..sPath end
  buf.origPath=sPath; buf.sPath=sPath
  buf.meta={}; buf.cache={}; buf.lru={}; buf.nCached=0
  buf.offsets={}; buf.swapped={}; buf.modified=false
  buf.nPages=0; buf.nTotal=0
  buf.tSegCache={}; buf.tLineVer={}; buf.nEditVer=0; buf.bStateDirty=true
  if HL then buf.tLang=HL.detect(sPath) end
  local nByte=0; local nLIP=0; local nPN=1; local nPSB=0; local bEndsNL=false
  while true do
    local sC=fs.read(h,4096); if not sC then break end
    bEndsNL=false
    for i=1,#sC do
      if sC:byte(i)==10 then
        nLIP=nLIP+1; buf.nTotal=buf.nTotal+1; bEndsNL=true
        if nLIP>=PAGE_SZ then
          buf.meta[nPN]=nLIP; buf.offsets[nPN]={nPSB, nByte+i-nPSB}
          nPN=nPN+1; nPSB=nByte+i; nLIP=0
        end
      else bEndsNL=false end
    end
    nByte=nByte+#sC
  end
  fs.close(h)
  if not bEndsNL and nByte>0 then nLIP=nLIP+1; buf.nTotal=buf.nTotal+1 end
  if nLIP>0 then
    buf.meta[nPN]=nLIP; buf.offsets[nPN]={nPSB, nByte-nPSB}
  elseif buf.nTotal==0 then
    buf.meta[1]=1; buf.offsets[1]={0,0}; nPN=1; buf.nTotal=1
  end
  buf.nPages=nPN
  return true
end

local function saveFile(sPath)
  sPath=sPath or buf.sPath
  if not sPath then return false,"No filename" end
  local h=fs.open(sPath,"w")
  if not h then return false,"Cannot write: "..sPath end
  for nP=1,buf.nPages do
    if (buf.meta[nP] or 0)>0 then
      local tL
      if buf.cache[nP] then tL=buf.cache[nP].lines
      elseif buf.swapped[nP] then tL=readSwap(nP)
      else tL=readOrigPage(nP) end
      for i,s in ipairs(tL) do fs.write(h,s); fs.write(h,"\n") end
      if not buf.cache[nP] then tL=nil end
    end
    pcall(function() syscall("process_yield") end)
  end
  fs.close(h)
  for nP in pairs(buf.swapped) do fs.remove(SWAP_DIR.."/p"..nP) end
  buf.swapped={}
  for _,pg in pairs(buf.cache) do pg.dirty=false end
  buf.modified=false; buf.sPath=sPath
  local tOC,tOL,nON = buf.cache, buf.lru, buf.nCached
  openFile(sPath)
  buf.cache=tOC; buf.lru=tOL; buf.nCached=nON
  return true
end

local function initEmpty()
  buf.meta={1}; buf.nPages=1; buf.nTotal=1
  buf.offsets={[1]={0,0}}
  buf.cache={[1]={lines={""},dirty=false}}; buf.nCached=1
  buf.lru={1}; buf.tSegCache={}; buf.tLineVer={}; buf.nEditVer=0
  buf.bStateDirty=true
end

-- =============================================
-- 5. EDITOR STATE
-- =============================================

local nCL, nCC = 1, 1
local nTop, nLeft = 1, 1
local sMode   = "start"
local sCmdBuf = ""
local sSearch = ""
local sTerm   = ""
local sMsg    = ""
local sYank   = ""
local bYLine  = false
local bRun    = true
local sPend   = nil

local tUndo = {}
local function undoPush(op,ln,old)
  tUndo[#tUndo+1]={op=op,ln=ln,old=old}
  local mx = MAX_UNDO
  local nFree = computer.freeMemory()
  if nFree < 65536 then mx = 3 elseif nFree < 131072 then mx = 5 end
  while #tUndo > mx do table.remove(tUndo,1) end
end
local function undoPop()
  if #tUndo==0 then sMsg="Already at oldest change"; return end
  local u=table.remove(tUndo)
  if u.op=="set" then setLine(u.ln,u.old)
  elseif u.op=="ins" then deleteLine(u.ln)
  elseif u.op=="del" then insertLine(u.ln-1,u.old) end
  buf.modified=true
end

local function clamp(n,lo,hi) return math.max(lo,math.min(hi,n)) end
local function curL() return getLine(nCL) end
local function fixCol()
  local mx=#curL()
  if sMode=="normal" then mx=math.max(1,mx) end
  if sMode=="insert" then mx=mx+1 end
  nCC=clamp(nCC,1,mx)
end

-- =============================================
-- 6. DIRECTORY TREE (fixed)
-- =============================================

local bTreeOpen = false
local sTreeRoot = env.PWD or "/"
local tTreeExpanded = {}
local nTreeSel = 1
local nTreeScroll = 0
local tTreeEntries = nil

local function buildTreeEntries()
  local t = {}
  local function walk(sDir, depth)
    -- Normalise: ensure no trailing slash except for root
    if sDir ~= "/" and sDir:sub(-1) == "/" then
      sDir = sDir:sub(1,-2)
    end
    local tList = fs.list(sDir)
    if not tList or type(tList) ~= "table" then return end
    table.sort(tList)
    local dirs, files = {}, {}
    for _,sN in ipairs(tList) do
      if type(sN) == "string" then
        if sN:sub(-1)=="/" then dirs[#dirs+1]=sN else files[#files+1]=sN end
      end
    end
    for _,sN in ipairs(dirs) do
      local sClean = sN:sub(1,-2)
      local sFull = sDir == "/" and ("/"..sClean) or (sDir.."/"..sClean)
      local bExp = tTreeExpanded[sFull]
      t[#t+1] = {name=sClean, path=sFull, isDir=true, depth=depth, expanded=bExp}
      if bExp then walk(sFull, depth+1) end
    end
    for _,sN in ipairs(files) do
      local sFull = sDir == "/" and ("/"..sN) or (sDir.."/"..sN)
      t[#t+1] = {name=sN, path=sFull, isDir=false, depth=depth}
    end
  end
  walk(sTreeRoot, 0)
  return t
end

local function treeRefresh()
  tTreeEntries = buildTreeEntries()
  if not tTreeEntries then tTreeEntries = {} end
  if nTreeSel > #tTreeEntries then nTreeSel = math.max(1,#tTreeEntries) end
end

local function treeToggle()
  bTreeOpen = not bTreeOpen
  if bTreeOpen and not tTreeEntries then treeRefresh() end
end

-- =============================================
-- 7. XE CONTEXT
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
if not ctx then print("xevi: no XE context"); return end
local W, H = ctx.W, ctx.H
local STATUS_Y = H
local EDIT_H = H - 1

-- =============================================
-- 8. COLORS
-- =============================================

local C = {
  bg=0x0A0A1A, fg=0xCCCCDD, gut=0x555566, gutBg=0x0E0E22,
  curLn=0x141430, cursor=0xFFFFFF, tilde=0x333355,
  barBg=0x0D2B52, barFg=0xFFFFFF,
  modeN=0x55FF55, modeI=0xFF5555, modeC=0x5599FF, modeS=0xFFFF55,
  treeBg=0x0C0C1E, treeFg=0x888899, treeDir=0x55AAFF,
  treeSel=0xFFFF00, treeSelBg=0x222244, treeBorder=0x333355,
  dropBg=0x111133, dropSel=0xFFFF00, dropSelBg=0x222266,
  dropCmd=0x55DDDD, dropDesc=0x777799,
  startFg=0x557799, startAcc=0x55FFFF, startKey=0xFFFF55,
}

-- =============================================
-- 9. COMMAND DEFINITIONS & FUZZY SEARCH
-- =============================================

local tCommandDefs = {
  {cmd="w",    desc="Write file",       alias={"write"}},
  {cmd="q",    desc="Quit",             alias={"quit"}},
  {cmd="wq",   desc="Write and quit",   alias={"x"}},
  {cmd="q!",   desc="Force quit",       alias={}},
  {cmd="e",    desc="Open file...",     alias={"edit"}},
  {cmd="new",  desc="New empty buffer", alias={}},
  {cmd="set",  desc="Set option",       alias={}},
  {cmd="qa",   desc="Quit all",         alias={"qall"}},
  {cmd="tree", desc="Toggle file tree", alias={"Explore"}},
}

local tCmdSugg = {}
local nSuggSel = 0
local nSuggMax = math.min(8, EDIT_H - 2)

local function fuzzyMatch(sQ, sT)
  if #sQ==0 then return true, 0 end
  local q,t = sQ:lower(), sT:lower()
  if t:sub(1,#q)==q then return true,100 end
  if t:find(q,1,true) then return true,50 end
  local qi=1
  for ti=1,#t do
    if t:sub(ti,ti)==q:sub(qi,qi) then
      qi=qi+1; if qi>#q then return true,10 end
    end
  end
  return false,0
end

local function updateSuggestions()
  tCmdSugg = {}
  local sQ = sCmdBuf:match("^(%S+)") or sCmdBuf
  for _,def in ipairs(tCommandDefs) do
    local bM,nS = fuzzyMatch(sQ, def.cmd)
    if not bM then
      for _,a in ipairs(def.alias or {}) do bM,nS=fuzzyMatch(sQ,a); if bM then break end end
    end
    if not bM and def.desc then bM,nS=fuzzyMatch(sQ,def.desc); if bM then nS=nS-20 end end
    if bM then tCmdSugg[#tCmdSugg+1]={def=def,score=nS} end
  end
  table.sort(tCmdSugg, function(a,b) return a.score>b.score end)
  while #tCmdSugg>nSuggMax do tCmdSugg[#tCmdSugg]=nil end
  if nSuggSel>#tCmdSugg then nSuggSel=#tCmdSugg end
end

-- =============================================
-- 10. RENDERING HELPERS
-- =============================================

local function gutW()
  if not cfg.lineNumbers then return 0 end
  return #tostring(buf.nTotal)+2
end

local function editStartX()
  return bTreeOpen and (TREE_W+1) or 1
end

local function editW()
  return W - editStartX() + 1 - gutW()
end

local function ensureVis()
  if nCL<nTop+SCROLL_OFF then nTop=math.max(1,nCL-SCROLL_OFF) end
  if nCL>=nTop+EDIT_H-SCROLL_OFF then nTop=nCL-EDIT_H+SCROLL_OFF+1 end
  local tw=editW()
  if nCC<nLeft then nLeft=nCC end
  if nCC>=nLeft+tw then nLeft=nCC-tw+1 end
end

local function recomputeState()
  -- Always clear dirty flag; populate block state for ANY language
  buf.bStateDirty = false
  if not HL or not buf.tLang then return end
  local sBS = buf.tLang.blockComment and buf.tLang.blockComment[1]
  local sBE = buf.tLang.blockComment and buf.tLang.blockComment[2]
  if not sBS then
    -- No block comments: all lines start outside block comment
    local nFrom = math.max(1,nTop-20)
    local nTo   = math.min(buf.nTotal,nTop+EDIT_H+5)
    for i=nFrom,nTo do buf.tBlkState[i]=false end
    return
  end
  local nFrom=math.max(1,nTop-20)
  local nTo=math.min(buf.nTotal,nTop+EDIT_H+5)
  local bIn=false
  for i=nFrom,nTo do
    buf.tBlkState[i]=bIn
    local s=getLine(i); local p=1
    while p<=#s do
      if bIn then
        local e=s:find(sBE,p,true)
        if e then bIn=false; p=e+#sBE else break end
      else
        if p+#sBS-1<=#s and s:sub(p,p+#sBS-1)==sBS then bIn=true; p=p+#sBS
        else p=p+1 end
      end
    end
  end
end

local nPrevBufTop = 0
local nScrollCooldown = 0

-- =============================================
-- 11. RENDERING
-- =============================================

local function renderTree()
  if not bTreeOpen then return end
  local tw = TREE_W
  ctx:fill(1,1,tw,EDIT_H," ",C.treeFg,C.treeBg)
  local sTitle = sTreeRoot:match("[^/]+$") or sTreeRoot
  if #sTitle > tw-2 then sTitle = sTitle:sub(1,tw-5).."..." end
  ctx:text(2,1," "..sTitle.." ",C.startAcc,C.treeBg)
  for row=1,EDIT_H do ctx:text(tw,row,"|",C.treeBorder,C.treeBg) end
  if not tTreeEntries or #tTreeEntries==0 then
    ctx:text(2,3,"(empty)",C.treeFg,C.treeBg)
    return
  end
  local nVis = EDIT_H - 2
  if nTreeSel < nTreeScroll+1 then nTreeScroll = nTreeSel-1 end
  if nTreeSel > nTreeScroll+nVis then nTreeScroll = nTreeSel-nVis end
  nTreeScroll = math.max(0, math.min(nTreeScroll, #tTreeEntries-nVis))
  for i=1,nVis do
    local idx = nTreeScroll + i
    if idx > #tTreeEntries then break end
    local e = tTreeEntries[idx]
    local row = 1 + i
    local bSel = (idx == nTreeSel)
    local bg = bSel and C.treeSelBg or C.treeBg
    ctx:fill(1,row,tw-1,1," ",C.treeFg,bg)
    local indent = string.rep(" ", e.depth*2)
    local icon = ""
    if e.isDir then icon = e.expanded and "v " or "> " end
    local sLabel = indent..icon..e.name
    if #sLabel > tw-3 then sLabel = sLabel:sub(1,tw-6).."..." end
    local fg = e.isDir and C.treeDir or C.treeFg
    if bSel then fg = C.treeSel end
    ctx:text(2,row,sLabel,fg,bg)
  end
end

local function renderEditor()
  if buf.bStateDirty then recomputeState() end
  ensureVis()
  if nTop ~= nPrevBufTop then nScrollCooldown=3; nPrevBufTop=nTop end
  if nScrollCooldown>0 then nScrollCooldown=nScrollCooldown-1 end

  local gw = gutW()
  local esx = editStartX()
  local tw = editW()

  -- evict far-off syntax cache entries to save memory
  if buf.tSegCache then
    local nLo,nHi = nTop-EDIT_H, nTop+EDIT_H*2
    for nL in pairs(buf.tSegCache) do
      if nL<nLo or nL>nHi then buf.tSegCache[nL]=nil end
    end
  end

  ctx:fill(esx,1,gw,EDIT_H," ",C.gut,C.gutBg)
  ctx:fill(esx+gw,1,tw,EDIT_H," ",C.fg,C.bg)

  -- Determine whether syntax colouring is possible
  local bScrolling = (nScrollCooldown > 0)
  local bCanSyntax = (not bScrolling) and HL ~= nil and buf.tLang ~= nil
      and buf.tLang.name ~= "Text"
      and computer.freeMemory() > 32768  -- lowered threshold from 49152

  for row=1,EDIT_H do
    local nLine = nTop+row-1
    if nLine>buf.nTotal then
      ctx:text(esx+gw,row,"~",C.tilde,C.bg)
    else
      local sLine=getLine(nLine)
      local bCur=(nLine==nCL)
      local nBg=bCur and C.curLn or C.bg
      if cfg.lineNumbers then
        local sN=tostring(nLine)
        ctx:text(esx,row,string.rep(" ",gw-1-#sN)..sN.." ",C.gut,C.gutBg)
      end
      if bCur then ctx:fill(esx+gw,row,tw,1," ",C.fg,C.curLn) end
      local nX=esx+gw
      if bCanSyntax then
        local bIB = buf.tBlkState[nLine] or false
        local lineVer = buf.tLineVer[nLine] or 0
        local cKey = lineVer*2+(bIB and 1 or 0)
        local cached = buf.tSegCache[nLine]
        local tSegs
        if cached and cached[1]==cKey and cached[3]==nLeft and cached[4]==tw then
          tSegs=cached[2]
        else
          tSegs=HL.segments(sLine,nLeft,tw,buf.tLang,bIB)
          buf.tSegCache[nLine]={cKey,tSegs,nLeft,tw}
        end
        if tSegs then
          for _,seg in ipairs(tSegs) do
            ctx:text(nX,row,seg[1],seg[2],nBg)
            nX=nX+ulen(seg[1])
          end
        end
      else
        local sV=""
        if #sLine>=nLeft then sV=sLine:sub(nLeft,nLeft+tw-1) end
        if #sV<tw then sV=sV..string.rep(" ",tw-#sV) end
        ctx:text(nX,row,sV,C.fg,nBg)
      end
      -- cursor
      if bCur then
        local cX=esx+gw+nCC-nLeft
        if cX>=esx+gw and cX<esx+gw+tw then
          local cC=(nCC<=#sLine) and sLine:sub(nCC,nCC) or " "
          ctx:text(cX,row,cC,C.bg,C.cursor)
        end
      end
      -- search highlight
      if #sTerm>0 and sLine:find(sTerm,1,true) then
        local p=1
        while true do
          local f=sLine:find(sTerm,p,true)
          if not f then break end
          local sX=esx+gw+f-nLeft
          if sX+#sTerm-1>=esx+gw and sX<=esx+gw+tw then
            local vis=sTerm
            if f<nLeft then vis=vis:sub(nLeft-f+1) end
            if #vis>0 then
              ctx:text(math.max(sX,esx+gw),row,vis:sub(1,tw),0x000000,0xFFFF00)
            end
          end
          p=f+1
        end
      end
    end
  end
end

local function renderStartScreen()
  local tLogo = {
    "               _  ",
    " __  _____ _ _(_) ",
    " \\ \\/ / -_) V / | ",
    "  >  <\\___|\\__/|_| ",
    " /_/\\_\\            ",
  }
  local nMY = math.floor(H/2)-6
  local nMX = math.floor(W/2)-10
  for i,s in ipairs(tLogo) do ctx:text(nMX,nMY+i,s,C.startAcc) end
  local nY = nMY+#tLogo+2
  ctx:text(nMX,nY,"XE Visual Editor v4.0",C.startFg); nY=nY+2
  local tAct = {{"n","New buffer"},{"e","Open file..."},{"t","Toggle tree"},{"q","Quit"}}
  for _,t in ipairs(tAct) do
    ctx:text(nMX+2,nY,t[1],C.startKey)
    ctx:text(nMX+6,nY,t[2],C.fg); nY=nY+1
  end
end

local function renderStatusBar()
  ctx:fill(1,STATUS_Y,W,1," ",C.barFg,C.barBg)
  if sMode=="start" then
    ctx:text(2,STATUS_Y," xevi 4.0 ",C.barFg,C.barBg); return
  end
  local tM={normal={" NORMAL ",C.modeN},insert={" INSERT ",C.modeI},
            command={" COMMAND ",C.modeC},search={" SEARCH ",C.modeS},
            tree={" TREE ",C.startAcc}}
  local m=tM[sMode] or {" ? ",C.barFg}
  ctx:text(1,STATUS_Y,m[1],C.bg,m[2])
  local nX=#m[1]+2
  local sN=buf.sPath and (buf.sPath:match("[^/]+$") or buf.sPath) or "[No Name]"
  local sMod=buf.modified and " [+]" or ""
  ctx:text(nX,STATUS_Y,sN..sMod,C.barFg,C.barBg)
  nX=nX+#sN+#sMod+2
  if buf.tLang and buf.tLang.name~="Text" then
    ctx:text(nX,STATUS_Y,buf.tLang.name,C.gut,C.barBg)
  end
  local nFree=math.floor(computer.freeMemory()/1024)
  local sR=string.format("Ln %d/%d Col %d  %dKB ",nCL,buf.nTotal,nCC,nFree)
  ctx:text(W-#sR+1,STATUS_Y,sR,C.barFg,C.barBg)
  if sMode=="command" then
    ctx:textPad(1,STATUS_Y,W,":"..sCmdBuf.."_",C.fg,C.bg)
  elseif sMode=="search" then
    ctx:textPad(1,STATUS_Y,W,"/"..sSearch.."_",C.fg,C.bg)
  elseif #sMsg>0 then
    ctx:text(1,STATUS_Y,sMsg,C.barFg,C.barBg); sMsg=""
  end
end

local function renderSuggestions()
  if sMode~="command" or #tCmdSugg==0 then return end
  local nCount=math.min(#tCmdSugg,nSuggMax)
  local nDropW=math.min(42,W-2)
  local nCmdW=14; local nDescW=nDropW-nCmdW-3
  for i=1,nCount do
    local nY=STATUS_Y-1-(i-1)
    if nY<1 then break end
    local def=tCmdSugg[i].def
    local bSel=(i==nSuggSel)
    local sBg=bSel and C.dropSelBg or C.dropBg
    ctx:fill(2,nY,nDropW,1," ",C.fg,sBg)
    ctx:text(2,nY,bSel and "> " or "  ",C.dropSel,sBg)
    local sCmd=def.cmd
    if #sCmd>nCmdW then sCmd=sCmd:sub(1,nCmdW-1) end
    ctx:text(4,nY,sCmd,bSel and C.dropSel or C.dropCmd,sBg)
    if def.desc and nDescW>4 then
      local sDesc=def.desc
      if #sDesc>nDescW then sDesc=sDesc:sub(1,nDescW-1) end
      ctx:text(4+nCmdW+1,nY,sDesc,bSel and C.dropSel or C.dropDesc,sBg)
    end
  end
end

local function render()
  ctx:clear(C.bg)
  if sMode=="start" then
    renderStartScreen()
    if bTreeOpen then renderTree() end
  else
    if bTreeOpen then renderTree() end
    renderEditor()
  end
  renderStatusBar()
  renderSuggestions()
end

-- =============================================
-- 12. SEARCH
-- =============================================

local function searchFwd(from,col)
  if #sTerm==0 then return nil end
  for i=from,buf.nTotal do
    local p=getLine(i):find(sTerm,(i==from) and (col+1) or 1,true)
    if p then return i,p end
  end
  for i=1,from do
    local p=getLine(i):find(sTerm,1,true)
    if p then return i,p end
  end
end

local function searchBwd(from,col)
  if #sTerm==0 then return nil end
  for i=from,1,-1 do
    local s=getLine(i)
    local mx=(i==from) and (col-1) or #s
    local last,f=nil,1
    while true do
      local p=s:find(sTerm,f,true)
      if not p or p>mx then break end
      last=p; f=p+1
    end
    if last then return i,last end
  end
end

-- =============================================
-- 13. WORD MOTION
-- =============================================

local function nextWord(s,c)
  while c<=#s and s:sub(c,c)~=" " do c=c+1 end
  while c<=#s and s:sub(c,c)==" " do c=c+1 end; return c
end
local function prevWord(s,c)
  c=c-1; while c>1 and s:sub(c,c)==" " do c=c-1 end
  while c>1 and s:sub(c-1,c-1)~=" " do c=c-1 end; return c
end

-- =============================================
-- 14. NORMAL MODE
-- =============================================

local function handleNormal(k)
  if sPend=="g" then
    sPend=nil
    if k=="g" then nCL=1; nCC=1; fixCol() end
    return
  end
  if sPend=="d" then
    sPend=nil
    if k=="d" then
      undoPush("del",nCL,getLine(nCL))
      sYank=getLine(nCL); bYLine=true
      deleteLine(nCL)
      nCL=clamp(nCL,1,buf.nTotal); fixCol()
    end; return
  end
  if sPend=="y" then
    sPend=nil
    if k=="y" then sYank=getLine(nCL); bYLine=true; sMsg="1 line yanked" end
    return
  end

  if     k=="h" or k=="\27[D" then nCC=prevCharB(curL(),nCC); fixCol()
  elseif k=="l" or k=="\27[C" then nCC=nextCharB(curL(),nCC); fixCol()
  elseif k=="j" or k=="\27[B" then nCL=math.min(nCL+1,buf.nTotal); fixCol()
  elseif k=="k" or k=="\27[A" then nCL=math.max(nCL-1,1); fixCol()
  elseif k=="0" or k=="\27[H" then nCC=1
  elseif k=="$" or k=="\27[F" then nCC=#curL(); fixCol()
  elseif k=="w" then nCC=nextWord(curL(),nCC); fixCol()
  elseif k=="b" then nCC=prevWord(curL(),nCC); fixCol()
  elseif k=="G" then nCL=buf.nTotal; fixCol()
  elseif k=="g" then sPend="g"
  elseif k=="\27[5~" then nCL=math.max(1,nCL-EDIT_H); fixCol()
  elseif k=="\27[6~" then nCL=math.min(buf.nTotal,nCL+EDIT_H); fixCol()
  elseif k=="i" then undoPush("set",nCL,curL()); sMode="insert"
  elseif k=="a" then
    undoPush("set",nCL,curL()); sMode="insert"
    if #curL()>0 then nCC=nextCharB(curL(),nCC) end
  elseif k=="A" then undoPush("set",nCL,curL()); sMode="insert"; nCC=#curL()+1
  elseif k=="o" then
    local sI=""
    if cfg.autoIndent then sI=(curL():match("^(%s*)") or "") end
    insertLine(nCL,sI); undoPush("ins",nCL+1,nil)
    nCL=nCL+1; nCC=#sI+1; sMode="insert"
  elseif k=="O" then
    insertLine(nCL-1,""); undoPush("ins",nCL,nil)
    nCC=1; sMode="insert"
  elseif k=="x" then
    local s=curL()
    if #s>0 and nCC<=#s then
      undoPush("set",nCL,s)
      local nb = charBytes(s,nCC)
      setLine(nCL, s:sub(1,nCC-1)..s:sub(nCC+nb))
      fixCol()
    end
  elseif k=="d" then sPend="d"
  elseif k=="y" then sPend="y"
  elseif k=="p" then
    if #sYank>0 then
      if bYLine then
        insertLine(nCL,sYank); undoPush("ins",nCL+1,nil)
        nCL=nCL+1; nCC=1
      else
        undoPush("set",nCL,curL())
        local s=curL()
        setLine(nCL, s:sub(1,nCC)..sYank..s:sub(nCC+1))
        nCC=nCC+#sYank
      end
      fixCol()
    end
  elseif k=="J" then
    if nCL<buf.nTotal then
      undoPush("set",nCL,curL())
      local nO=#curL()
      setLine(nCL, curL().." "..getLine(nCL+1))
      deleteLine(nCL+1); nCC=nO+1
    end
  elseif k=="u" then undoPop()
  elseif k=="/" then sMode="search"; sSearch=""
  elseif k=="n" then
    local nl,nc=searchFwd(nCL,nCC)
    if nl then nCL=nl; nCC=nc; fixCol() else sMsg="Not found" end
  elseif k=="N" then
    local nl,nc=searchBwd(nCL,nCC)
    if nl then nCL=nl; nCC=nc; fixCol() else sMsg="Not found" end
  elseif k==":" then sMode="command"; sCmdBuf=""; nSuggSel=0; updateSuggestions()
  elseif k=="\7" then
    sMsg=string.format('"%s" %s%dL %dC',
      buf.sPath or "[No Name]", buf.modified and "[+] " or "", buf.nTotal, #curL())
  end
end

-- =============================================
-- 15. INSERT MODE
-- =============================================

local function handleInsert(k)
  local s=curL()
  if k=="\27" then sMode="normal"; nCC=math.max(1,nCC-1); fixCol(); return end
  if k=="\b" then
    if nCC>1 then
      local pv = prevCharB(s, nCC)
      setLine(nCL, s:sub(1,pv-1)..s:sub(nCC))
      nCC=pv
    elseif nCL>1 then
      local sPrev=getLine(nCL-1); nCC=#sPrev+1
      setLine(nCL-1, sPrev..s); deleteLine(nCL); nCL=nCL-1
    end
  elseif k=="\n" then
    local sI=""
    if cfg.autoIndent then sI=(s:match("^(%s*)") or "") end
    setLine(nCL, s:sub(1,nCC-1))
    insertLine(nCL, sI..s:sub(nCC))
    nCL=nCL+1; nCC=#sI+1
  elseif k=="\t" then
    local sTab=string.rep(" ",TAB_SIZE)
    setLine(nCL, s:sub(1,nCC-1)..sTab..s:sub(nCC)); nCC=nCC+#sTab
  elseif k=="\27[A" then nCL=math.max(1,nCL-1); fixCol()
  elseif k=="\27[B" then nCL=math.min(buf.nTotal,nCL+1); fixCol()
  elseif k=="\27[D" then nCC=prevCharB(s,nCC); if nCC<1 then nCC=1 end
  elseif k=="\27[C" then nCC=nextCharB(s,nCC); if nCC>#s+1 then nCC=#s+1 end
  elseif k=="\27[H" then nCC=1
  elseif k=="\27[F" then nCC=#s+1
  elseif k and #k>=1 and k:byte()>=32 then
    setLine(nCL, s:sub(1,nCC-1)..k..s:sub(nCC)); nCC=nCC+#k
  end
end

-- =============================================
-- 16. COMMAND MODE
-- =============================================

local function execCmd(sCmd)
  local sC=sCmd:match("^(%S+)")
  local sA=sCmd:match("^%S+%s+(.+)$")
  if sC=="w" or sC=="write" then
    if sA then buf.sPath=sA end
    local ok,err=saveFile(buf.sPath)
    if ok then ctx:toastSuccess("Written: "..(buf.sPath:match("[^/]+$") or buf.sPath))
    else ctx:toastError(err or "Write failed") end
  elseif sC=="q" or sC=="quit" then
    if buf.modified then sMsg="Unsaved changes (use :q!)"
    else bRun=false end
  elseif sC=="q!" then bRun=false
  elseif sC=="wq" or sC=="x" then
    if sA then buf.sPath=sA end
    local ok=saveFile(buf.sPath)
    if ok then bRun=false else ctx:toastError("Write failed") end
  elseif sC=="e" or sC=="edit" then
    if sA then
      local sP=sA
      if sP:sub(1,1)~="/" then sP=(env.PWD or "/").."/"..sP end
      sP=sP:gsub("//","/")
      local tL = fs.list(sP)
      if tL and type(tL)=="table" then
        sTreeRoot=sP; bTreeOpen=true; treeRefresh()
        sMode="tree"
      else
        local ok,err=openFile(sA)
        if ok then nCL=1; nCC=1; nTop=1; nLeft=1; sMode="normal"
          ctx:toastSuccess((buf.sPath:match("[^/]+$") or sA).." — "..buf.nTotal.."L")
        else ctx:toastError(err or "Open failed") end
      end
    else sMsg="Usage: :e <path>" end
  elseif sC=="new" then
    initEmpty(); buf.sPath=nil; buf.tLang=nil
    nCL=1; nCC=1; nTop=1; nLeft=1; sMode="normal"
  elseif sC=="tree" or sC=="Explore" then
    treeToggle()
    if bTreeOpen then sMode="tree" end
  elseif sC=="set" then
    if sA=="number" or sA=="nu" then cfg.lineNumbers=true
    elseif sA=="nonumber" or sA=="nonu" then cfg.lineNumbers=false
    elseif sA and sA:match("^tabsize=") then TAB_SIZE=tonumber(sA:match("=(%d+)")) or 2
    else sMsg="set: "..tostring(sA) end
  elseif sC=="qa" or sC=="qall" then bRun=false
  elseif tonumber(sC) then
    nCL=clamp(tonumber(sC),1,buf.nTotal); fixCol()
  else sMsg="Unknown: "..sCmd end
end

local function handleCommand(k)
  if k=="\27" then sMode="normal"; tCmdSugg={}; return end
  if k=="\t" then
    if nSuggSel>=1 and nSuggSel<=#tCmdSugg then
      sCmdBuf=tCmdSugg[nSuggSel].def.cmd; updateSuggestions()
    elseif #tCmdSugg>0 then nSuggSel=1 end
    return
  end
  if k=="\27[A" then
    if #tCmdSugg>0 then nSuggSel=nSuggSel+1; if nSuggSel>#tCmdSugg then nSuggSel=1 end end
    return
  end
  if k=="\27[B" then
    if #tCmdSugg>0 then nSuggSel=nSuggSel-1; if nSuggSel<1 then nSuggSel=#tCmdSugg end end
    return
  end
  if k=="\n" then
    sMode="normal"
    local sExec=sCmdBuf
    if nSuggSel>=1 and nSuggSel<=#tCmdSugg then
      local sDef=tCmdSugg[nSuggSel].def.cmd
      local sFirst=sCmdBuf:match("^(%S+)") or sCmdBuf
      local bM=fuzzyMatch(sFirst,sDef)
      if bM and #sFirst>0 then
        local sArgs=sCmdBuf:match("^%S+(.*)$") or ""
        sExec=sDef..sArgs
      end
    end
    sCmdBuf=""; tCmdSugg={}; nSuggSel=0
    execCmd(sExec); return
  end
  if k=="\b" then
    if #sCmdBuf>0 then sCmdBuf=sCmdBuf:sub(1,-2)
    else sMode="normal"; tCmdSugg={}; return end
  elseif k and #k==1 and k:byte()>=32 then sCmdBuf=sCmdBuf..k end
  nSuggSel=0; updateSuggestions()
  if #tCmdSugg>0 then nSuggSel=1 end
end

-- =============================================
-- 17. SEARCH MODE
-- =============================================

local function handleSearch(k)
  if k=="\27" then sMode="normal"; return end
  if k=="\n" then
    sMode="normal"; sTerm=sSearch; sSearch=""
    local nl,nc=searchFwd(nCL,nCC)
    if nl then nCL=nl; nCC=nc; fixCol()
    else sMsg="Not found: "..sTerm end
    return
  end
  if k=="\b" then
    if #sSearch>0 then sSearch=sSearch:sub(1,-2) else sMode="normal" end
  elseif k and #k>=1 and k:byte()>=32 then sSearch=sSearch..k end
end

-- =============================================
-- 18. TREE MODE (fixed)
-- =============================================

local function handleTree(k)
  if not tTreeEntries then treeRefresh() end
  if k=="\27" or k=="q" then sMode=(buf.nTotal>0 and buf.sPath) and "normal" or "start"; return end
  if k=="j" or k=="\27[B" then
    nTreeSel=math.min(nTreeSel+1, #tTreeEntries)
  elseif k=="k" or k=="\27[A" then
    nTreeSel=math.max(nTreeSel-1, 1)
  elseif k=="\n" then
    local e=tTreeEntries[nTreeSel]
    if e then
      if e.isDir then
        tTreeExpanded[e.path] = not tTreeExpanded[e.path] or nil
        treeRefresh()
      else
        local ok,err=openFile(e.path)
        if ok then
          nCL=1; nCC=1; nTop=1; nLeft=1; sMode="normal"
          ctx:toastSuccess((buf.sPath:match("[^/]+$") or e.name).." — "..buf.nTotal.."L")
        else ctx:toastError(err or "Open failed") end
      end
    end
  elseif k=="h" or k=="\27[D" then
    local e=tTreeEntries[nTreeSel]
    if e and e.isDir and tTreeExpanded[e.path] then
      tTreeExpanded[e.path]=nil; treeRefresh()
    elseif e then
      local sParent=e.path:match("^(.+)/[^/]+$")
      if sParent then
        for i,te in ipairs(tTreeEntries) do
          if te.path==sParent then nTreeSel=i; break end
        end
      end
    end
  elseif k=="l" or k=="\27[C" then
    local e=tTreeEntries[nTreeSel]
    if e and e.isDir and not tTreeExpanded[e.path] then
      tTreeExpanded[e.path]=true; treeRefresh()
    elseif e and not e.isDir then
      local ok,err=openFile(e.path)
      if ok then
        nCL=1; nCC=1; nTop=1; nLeft=1; sMode="normal"
        ctx:toastSuccess((buf.sPath:match("[^/]+$") or e.name).." — "..buf.nTotal.."L")
      end
    end
  elseif k=="r" or k=="R" then
    treeRefresh()
  elseif k=="-" then
    local sParent=sTreeRoot:match("^(.+)/[^/]+$") or "/"
    sTreeRoot=sParent; tTreeExpanded={}; treeRefresh(); nTreeSel=1
  end
end

-- =============================================
-- 19. INIT
-- =============================================

local sArg = nil
for _,a in ipairs(tArgs) do
  if a:sub(1,1)~="-" then sArg=a; break end
end

if sArg then
  local sP = sArg
  if sP:sub(1,1)~="/" then sP=(env.PWD or "/").."/"..sP end
  sP=sP:gsub("//","/")
  -- Remove trailing slash for directory check
  if #sP > 1 and sP:sub(-1) == "/" then sP = sP:sub(1,-2) end
  local tL = fs.list(sP)
  if tL and type(tL)=="table" then
    sTreeRoot=sP; bTreeOpen=true; treeRefresh()
    initEmpty()
    sMode="tree"
  else
    local ok,err=openFile(sArg)
    if ok then
      sMode="normal"
      sTreeRoot=buf.sPath:match("^(.+)/[^/]+$") or "/"
      ctx:toastInfo((buf.sPath:match("[^/]+$") or sArg).." — "..buf.nTotal.."L, "..
        buf.nPages.." pages")
    else
      ctx:toastError(err or "Open failed")
      initEmpty(); sMode="start"
    end
  end
else
  initEmpty(); sMode="start"
end

-- =============================================
-- 20. MAIN LOOP
-- =============================================

while bRun do
  ctx:beginFrame()
  render()
  local k = ctx:key()
  if k then
    if k=="\3" then
      if sMode~="normal" and sMode~="start" then
        sMode=(buf.sPath or buf.nTotal>1) and "normal" or "start"
        tCmdSugg={}; fixCol()
      else bRun=false end
    elseif sMode=="start" then
      if k=="n" or k=="i" then initEmpty(); sMode="normal"
      elseif k=="e" then sMode="command"; sCmdBuf="e "; nSuggSel=0; updateSuggestions()
      elseif k=="t" then treeToggle(); if bTreeOpen then sMode="tree" end
      elseif k=="q" then bRun=false
      elseif k==":" then sMode="command"; sCmdBuf=""; nSuggSel=0; updateSuggestions()
      end
    elseif sMode=="normal" then
      if k=="\14" then
        treeToggle()
        if bTreeOpen then sMode="tree" end
      else handleNormal(k) end
    elseif sMode=="insert" then handleInsert(k)
    elseif sMode=="command" then handleCommand(k)
    elseif sMode=="search" then handleSearch(k)
    elseif sMode=="tree" then
      if k=="\14" then
        treeToggle()
        sMode=(buf.sPath or buf.nTotal>1) and "normal" or "start"
      elseif k==":" then sMode="command"; sCmdBuf=""; nSuggSel=0; updateSuggestions()
      else handleTree(k) end
    end
  end
  -- Memory pressure relief (no collectgarbage available)
  if buf.tSegCache then
    local nFree = computer.freeMemory()
    if nFree < 65536 then
      buf.tSegCache = {}
      while #tUndo > 3 do table.remove(tUndo, 1) end
    end
  end
  ctx:endFrame()
end

-- =============================================
-- 21. CLEANUP
-- =============================================

for nP in pairs(buf.swapped) do pcall(fs.remove, SWAP_DIR.."/p"..nP) end
pcall(fs.remove, SWAP_DIR)
buf.cache=nil; buf.meta=nil; buf.offsets=nil; buf.tSegCache=nil
buf.tLineVer=nil; buf.tBlkState=nil; tUndo=nil; tTreeEntries=nil
ctx:destroy()