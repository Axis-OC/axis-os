
--
-- /usr/commands/axplorer.lua
-- AxisOS AXFS Drive File Explorer v1.0
-- Alt-screen, batch-rendered, dual-panel filesystem browser.
--
-- Browse AXFS v2 volumes on unmanaged drives directly
-- from sector-level access through the block device driver.
--
-- Controls:
--  Up/Down       Navigate
--  Right/Enter   Expand dir / enter dir / preview file
--  Left          Collapse / parent / back to tree
--  Tab           Switch panel (Tree <-> Entries)
--  /             Search (filename substring, Enter applies, Esc cancels)
--  Backspace     Go up one directory level
--  P             Toggle file preview (text / hex)
--  H             Toggle hex mode in preview
--  I             Show inode info for selected entry
--  D             Return to partition selector
--  R / F5        Refresh
--  Q / Ctrl+C    Quit
--  PgUp/PgDn     Page scroll
--  Home/End      Jump top/bottom
--

local fs  = require("filesystem")
local AX  = require("axfs_core")
local RDB = require("rdb")
local B   = require("bpack")
local args = env.ARGS or {}

local hIn = fs.open("/dev/tty", "r")
if not hIn then print("axplorer: no tty"); return end
fs.deviceControl(hIn, "set_mode", {"raw"})
local bSz, tSz = fs.deviceControl(hIn, "get_size", {})
local W = (bSz and tSz and tSz.w) or 80
local H = (bSz and tSz and tSz.h) or 25

-- =============================================
-- PALETTE & LAYOUT
-- =============================================

local FG     = 0xCCCCDD
local BG     = 0x0C0C1E
local SEL    = 0xFFFF00
local DIM    = 0x555577
local DIR_C  = 0x55AAFF
local FILE_C = 0xCCCCDD
local INL_C  = 0x778899
local SZ_C   = 0xBBBB55
local HDR_C  = 0x55FFFF
local ERR_C  = 0xFF5555
local OK_C   = 0x55FF55
local BAR_FG = 0xFFFFFF
local BAR_BG = 0x0D2B52

local TW = math.max(14, math.floor(W * 0.35))
local VX = TW + 2
local VW = math.max(10, W - VX + 1)
local BY = 3
local BH = H - 4

local E_CS = 10
local E_CT = 12
local E_CN = math.max(8, VW - E_CS - E_CT)

-- =============================================
-- STATE
-- =============================================

local g_sPage   = "parts"
local g_bRun    = true
local g_sMsg    = ""

-- Device
local g_hDev    = nil
local g_sDev    = nil
local g_oVol    = nil
local g_sVolLbl = ""

-- Partition list
local g_tParts   = {}
local g_nPartSel = 1
local g_nPartTop = 0

-- Tree (dirs only)
local g_tTree    = {}
local g_nTree    = 0
local g_nTSel    = 1
local g_nTTop    = 0
local g_tExpDir  = {}

-- Right panel entries
local g_tEnt     = {}
local g_nEnt     = 0
local g_nESel    = 1
local g_nETop    = 0

local g_bTFocus  = true
local g_sPreview = nil
local g_nPrevTop = 0
local g_bHex     = false

-- Search
local g_bSrchMode = false
local g_sSrchBuf  = ""
local g_sSearch   = nil

-- =============================================
-- BATCH RENDERER
-- =============================================

local tBat  = {}
local nBat  = 0

local function bp(x, y, s, fg, bg)
    nBat = nBat + 1
    local e = tBat[nBat]
    if e then e[1]=x;e[2]=y;e[3]=s;e[4]=fg or FG;e[5]=bg or BG
    else tBat[nBat] = {x, y, s, fg or FG, bg or BG} end
end

local function bFlush()
    if nBat > 0 then
        for i = nBat+1, #tBat do tBat[i] = nil end
        fs.deviceControl(hIn, "render_batch", tBat)
        nBat = 0
    end
end

local function gFill(x, y, w, h, fg, bg)
    fs.deviceControl(hIn, "gpu_fill", {x, y, w, h, " ", fg or FG, bg or BG})
end

local function pad(s, n)
    if #s >= n then return s:sub(1, n) end
    return s .. string.rep(" ", n - #s)
end

local function fmtSz(n)
    if not n or n < 0 then return "0 B" end
    if n >= 1048576 then return string.format("%.1f MB", n/1048576) end
    if n >= 1024    then return string.format("%.1f KB", n/1024) end
    return n .. " B"
end

local function yld()
    pcall(function() syscall("process_yield") end)
end

-- =============================================
-- DEVICE / PARTITION
-- =============================================

local function closeVol()
    if g_oVol then pcall(function() g_oVol:flush() end); g_oVol = nil end
    if g_hDev then fs.close(g_hDev); g_hDev = nil end
    g_sDev = nil; g_sVolLbl = ""
    g_tTree = {}; g_nTree = 0; g_tEnt = {}; g_nEnt = 0
    g_sPreview = nil; g_tExpDir = {}
end

local function scanPartitions()
    local tRes = {}
    local tDev = fs.list("/dev")
    if not tDev then return tRes end
    for _, sN in ipairs(tDev) do
        local sC = sN:gsub("/$", "")
        if sC:find("drive", 1, true) then
            local sP = "/dev/" .. sC
            local hD = fs.open(sP, "r")
            if hD then
                local bI, tI = fs.deviceControl(hD, "info", {})
                if bI and tI then
                    local ss = tI.sectorSize
                    local function rs(n)
                        local bO, d = fs.deviceControl(hD, "read_sector", {n+1})
                        return bO and d or nil
                    end
                    local sH = rs(0)
                    if sH and #sH >= 4 and sH:sub(1,4) == "RDSK" then
                        local tDisk = { sectorSize=ss, sectorCount=tI.sectorCount,
                            readSector=rs }
                        local tRdb = RDB.read(tDisk)
                        if tRdb then
                            for i, p in ipairs(tRdb.partitions) do
                                if p.fsType == RDB.FS_AXFS2 or p.fsType == RDB.FS_AXFS1 then
                                    tRes[#tRes+1] = {
                                        sDevPath  = sP,
                                        nIdx      = i - 1,
                                        sDevName  = p.deviceName or ("DH"..(i-1)),
                                        sLabel    = RDB.getDisplayLabel(p),
                                        sFsType   = RDB.fsTypeName(p.fsType),
                                        nStart    = p.startSector,
                                        nSize     = p.sizeSectors,
                                        nSecSz    = ss,
                                        nCapacity = tI.capacity or (tI.sectorCount * ss),
                                        nFlags    = p.flags or 0,
                                    }
                                end
                            end
                        end
                    end
                end
                fs.close(hD)
            end
        end
        yld()
    end
    return tRes
end

local function mountPart(tP)
    closeVol()
    local hD = fs.open(tP.sDevPath, "r")
    if not hD then return false, "Cannot open " .. tP.sDevPath end
    local bI, tI = fs.deviceControl(hD, "info", {})
    if not bI then fs.close(hD); return false, "Device info failed" end
    local ss  = tI.sectorSize
    local off = tP.nStart
    local tPD = {
        sectorSize  = ss,
        sectorCount = tP.nSize,
        readSector  = function(n)
            local bO, d = fs.deviceControl(hD, "read_sector", {off + n + 1})
            return bO and d or nil
        end,
        writeSector = function(n, d)
            d = B.pad(d or "", ss)
            return fs.deviceControl(hD, "write_sector", {off + n + 1, d:sub(1, ss)})
        end,
    }
    local vol, e = AX.mount(tPD, { cacheSize = 32 })
    if not vol then fs.close(hD); return false, tostring(e) end
    g_hDev = hD; g_sDev = tP.sDevPath; g_oVol = vol
    g_sVolLbl = tP.sLabel or tP.sDevName
    return true
end

-- =============================================
-- TREE
-- =============================================

local function buildTree()
    for i = 1, #g_tTree do g_tTree[i] = nil end
    g_nTree = 0
    if not g_oVol then return end

    local function add(d, nm, p, hk, ex)
        g_nTree = g_nTree + 1
        g_tTree[g_nTree] = {d, nm, p, hk, ex}
    end

    local function walk(sP, depth)
        local tL = g_oVol:listDir(sP)
        if not tL then return end
        table.sort(tL, function(a,b) return a.name < b.name end)
        for _, ent in ipairs(tL) do
            if ent.iType == 2 then
                local sC = sP == "/" and ("/"..ent.name) or (sP.."/"..ent.name)
                if g_sSearch and not ent.name:lower():find(g_sSearch,1,true) then
                    goto skip
                end
                local bEx = g_tExpDir[sC] or false
                local bHK = true
                if bEx then
                    bHK = false
                    local tS = g_oVol:listDir(sC)
                    if tS then
                        for _, s in ipairs(tS) do
                            if s.iType == 2 then bHK = true; break end
                        end
                    end
                end
                add(depth, ent.name, sC, bHK, bEx)
                if bEx then walk(sC, depth+1) end
                ::skip::
            end
        end
        if depth % 3 == 0 then yld() end
    end

    local bHasRoot = false
    local tR = g_oVol:listDir("/")
    if tR then
        for _, e in ipairs(tR) do
            if e.iType == 2 then bHasRoot = true; break end
        end
    end
    add(0, "/", "/", bHasRoot, true)
    walk("/", 1)

    if g_nTSel > g_nTree then g_nTSel = g_nTree end
    if g_nTSel < 1 then g_nTSel = 1 end
end

-- =============================================
-- ENTRIES (files + dirs in selected directory)
-- =============================================

local function loadEntries()
    for i = 1, #g_tEnt do g_tEnt[i] = nil end
    g_nEnt = 0; g_nESel = 1; g_nETop = 0; g_sPreview = nil
    if g_nTSel < 1 or g_nTSel > g_nTree or not g_oVol then return end
    local sP = g_tTree[g_nTSel][3]
    local tL = g_oVol:listDir(sP)
    if not tL then return end
    table.sort(tL, function(a,b)
        if a.iType==2 and b.iType~=2 then return true end
        if a.iType~=2 and b.iType==2 then return false end
        return a.name < b.name
    end)
    for _, ent in ipairs(tL) do
        if g_sSearch and not ent.name:lower():find(g_sSearch,1,true) then
            goto sk
        end
        g_nEnt = g_nEnt + 1
        g_tEnt[g_nEnt] = ent
        ::sk::
    end
end

-- =============================================
-- FILE PREVIEW & HEX DUMP
-- =============================================

local function loadPreview(sPath)
    if not g_oVol then g_sPreview = nil; return end
    local tS = g_oVol:stat(sPath)
    if not tS or tS.iType ~= 1 then g_sPreview = "(Not a regular file)"; return end
    local sD = g_oVol:readFile(sPath)
    if not sD then g_sPreview = "(Read error)"; return end
    if #sD > 6144 then sD = sD:sub(1,6144) end
    g_sPreview = sD; g_nPrevTop = 0
end

local function hexLines(sData, nMax)
    local tL = {}
    local nB = math.min(#sData, nMax * 16)
    for i = 0, nB-1, 16 do
        local tH, tA = {}, {}
        for j = 0, 15 do
            local idx = i+j+1
            if idx <= #sData then
                local b = sData:byte(idx)
                tH[#tH+1] = string.format("%02X", b)
                tA[#tA+1] = (b >= 32 and b < 127) and string.char(b) or "."
            else tH[#tH+1] = "  "; tA[#tA+1] = " " end
        end
        tL[#tL+1] = string.format("%04X: %s  %s", i,
            table.concat(tH, " "), table.concat(tA))
    end
    return tL
end

-- =============================================
-- SCROLL HELPERS
-- =============================================

local function treeVis()
    if g_nTSel < g_nTTop+1 then g_nTTop = g_nTSel-1 end
    if g_nTSel > g_nTTop+BH then g_nTTop = g_nTSel-BH end
    if g_nTTop < 0 then g_nTTop = 0 end
end

local function entVis()
    local dh = math.max(1, BH-2)
    if g_nESel < g_nETop+1 then g_nETop = g_nESel-1 end
    if g_nESel > g_nETop+dh then g_nETop = g_nESel-dh end
    if g_nETop < 0 then g_nETop = 0 end
end

local function partVis()
    if g_nPartSel < g_nPartTop+1 then g_nPartTop = g_nPartSel-1 end
    if g_nPartSel > g_nPartTop+(H-7) then g_nPartTop = g_nPartSel-(H-7) end
    if g_nPartTop < 0 then g_nPartTop = 0 end
end

-- =============================================
-- ENTRY PATH HELPER
-- =============================================

local function entryPath(nIdx)
    if nIdx < 1 or nIdx > g_nEnt or g_nTSel < 1 or g_nTSel > g_nTree then return nil end
    local sBase = g_tTree[g_nTSel][3]
    local sName = g_tEnt[nIdx].name
    return sBase == "/" and ("/"..sName) or (sBase.."/"..sName)
end

-- =============================================
-- RENDER: PARTITION SELECTOR
-- =============================================

local function renderParts()
    partVis()
    gFill(1, 1, W, H, FG, BG)

    bp(1, 1, pad(" AXFS Explorer — Select Partition", W), BAR_FG, BAR_BG)
    bp(1, 2, pad("", W), FG, BG)
    bp(2, 3, "Available AXFS Partitions:", HDR_C, BG)
    bp(2, 4, string.rep("-", W-2), DIM, BG)

    if #g_tParts == 0 then
        bp(3, 6, "No AXFS partitions found.", ERR_C, BG)
        bp(3, 7, "Ensure blkdev driver is loaded: insmod blkdev", DIM, BG)
        bp(3, 9, "Press R to rescan, Q to quit.", DIM, BG)
    else
        local nVis = math.min(#g_tParts, H - 7)
        for i = 1, nVis do
            local idx = i + g_nPartTop
            if idx > #g_tParts then break end
            local p = g_tParts[idx]
            local y = 4 + i
            local bS = (idx == g_nPartSel)
            local sLine = string.format(" %-24s  %-6s  %-10s  %-8s  %s",
                p.sDevPath:sub(1,24), p.sDevName,
                p.sLabel:sub(1,10), p.sFsType,
                fmtSz(p.nSize * p.nSecSz))
            bp(1, y, pad(sLine, W), bS and SEL or FG, BG)
        end
    end

    bp(1, H-1, pad(string.rep("-", W), W), DIM, BG)
    if #g_sMsg > 0 then
        bp(1, H, pad(" "..g_sMsg, W), SEL, BAR_BG); g_sMsg = ""
    else
        local sR = string.format(" %d partition(s) ", #g_tParts)
        local sK = " Enter:Mount  R:Rescan  Q:Quit"
        bp(1, H, pad(sK .. string.rep(" ", math.max(0, W-#sK-#sR)) .. sR, W), BAR_FG, BAR_BG)
    end
    bFlush()
end

-- =============================================
-- RENDER: BROWSE (TREE + ENTRIES/PREVIEW)
-- =============================================

local function renderEntries()
    bp(VX, BY, pad(pad("Name", E_CN) .. pad("Size", E_CS) .. "Type", VW), DIM, BG)
    bp(VX, BY+1, pad(string.rep("-", math.min(VW, 56)), VW), DIM, BG)

    local dh = math.max(1, BH-2)
    for i = 1, dh do
        local y = BY + 1 + i
        local idx = i + g_nETop
        if idx >= 1 and idx <= g_nEnt then
            local ent = g_tEnt[idx]
            local bS  = (idx == g_nESel) and not g_bTFocus
            local bDir = ent.iType == 2

            local sIco = bDir and "d" or (ent.iType == 3 and "l" or " ")
            local sNm  = ent.name
            if bDir then sNm = sNm .. "/" end
            local nNMax = E_CN - 3
            if #sNm > nNMax then sNm = sNm:sub(1, nNMax-2)..".." end

            local sSz = bDir and "     -" or string.format("%8s", fmtSz(ent.size or 0))
            local sTp = bDir and "DIR" or "FILE"
            if not bDir and ent.inline then sTp = sTp .. " inl" end

            local fI = bS and SEL or DIM
            local fN = bS and SEL or (bDir and DIR_C or (ent.inline and INL_C or FILE_C))
            local fS = bS and SEL or SZ_C
            local fT = bS and SEL or DIM

            bp(VX,        y, sIco .. " ", fI, BG)
            bp(VX+2,      y, pad(sNm, E_CN-2), fN, BG)
            bp(VX+E_CN,   y, pad(sSz, E_CS), fS, BG)
            bp(VX+E_CN+E_CS, y, pad(sTp, E_CT), fT, BG)
        else
            bp(VX, y, pad("", VW), FG, BG)
        end
    end
end

local function renderPreview()
    local sHdr = " Preview" .. (g_bHex and " [HEX]" or " [TEXT]")
    bp(VX, BY, pad(sHdr, VW), HDR_C, BG)
    bp(VX, BY+1, pad(string.rep("-", math.min(VW, 56)), VW), DIM, BG)

    if not g_sPreview then
        bp(VX+2, BY+2, "(no preview available)", DIM, BG)
        for i = 3, BH-1 do bp(VX, BY+i, pad("", VW), FG, BG) end
        return
    end

    local tL
    local dh = math.max(1, BH-2)
    if g_bHex then
        tL = hexLines(g_sPreview, dh + g_nPrevTop + 20)
    else
        tL = {}
        for sLine in (g_sPreview.."\n"):gmatch("([^\n]*)\n") do
            tL[#tL+1] = sLine
        end
    end

    for i = 1, dh do
        local y = BY + 1 + i
        local idx = i + g_nPrevTop
        if idx >= 1 and idx <= #tL then
            local sL = tL[idx]
            if #sL > VW then sL = sL:sub(1, VW) end
            bp(VX, y, pad(sL, VW), g_bHex and SZ_C or OK_C, BG)
        else
            bp(VX, y, pad("", VW), FG, BG)
        end
    end
end

local function renderBrowse()
    treeVis(); entVis()

    -- Volume info for header
    local sInfo = g_sVolLbl
    if g_oVol then
        local tVI = g_oVol:info()
        if tVI then
            sInfo = string.format("%s — %s  %s / %s  (%d inodes free)",
                g_sVolLbl, tVI.label or "?",
                fmtSz((tVI.maxBlocks - tVI.freeBlocks) * tVI.sectorSize),
                fmtSz(tVI.maxBlocks * tVI.sectorSize),
                tVI.freeInodes or 0)
        end
    end
    bp(1, 1, pad(" AXFS Explorer — " .. sInfo, W), BAR_FG, BAR_BG)

    -- Current path
    local sPath = (g_nTSel >= 1 and g_nTSel <= g_nTree) and g_tTree[g_nTSel][3] or "/"
    local sFilter = g_sSearch and ("  /" .. g_sSearch) or ""
    local sPanel = g_bTFocus and "[Tree]" or (g_sPreview and "[Preview]" or "[Files]")
    local sHdr = " " .. sPath .. sFilter
    if #sHdr + #sPanel + 2 <= W then
        sHdr = sHdr .. string.rep(" ", W - #sHdr - #sPanel - 1) .. sPanel
    end
    bp(1, 2, pad(sHdr, W), HDR_C, BG)

    -- Tree rows
    for row = 1, BH do
        local y = BY + row - 1
        local idx = row + g_nTTop
        if idx >= 1 and idx <= g_nTree then
            local t = g_tTree[idx]
            local sI = string.rep(" ", t[1]*2)
            local sC = t[4] and (t[5] and "v" or ">") or "-"
            local sN = t[2]
            local nM = TW - #sI - 3
            if nM < 1 then nM = 1 end
            if #sN > nM then sN = sN:sub(1, math.max(1, nM-2))..".." end
            local fg = (idx == g_nTSel) and (g_bTFocus and SEL or DIM) or DIR_C
            bp(1, y, pad(sI..sC.." "..sN, TW), fg, BG)
        else
            bp(1, y, pad("", TW), FG, BG)
        end
        bp(TW+1, y, "|", DIM, BG)
    end

    -- Right panel
    if g_sPreview then renderPreview() else renderEntries() end

    -- Status bar
    bp(1, H-1, pad(string.rep("-", W), W), DIM, BG)

    if g_bSrchMode then
        bp(1, H, pad(" /"..g_sSrchBuf.."_", W), SEL, BAR_BG)
    elseif #g_sMsg > 0 then
        bp(1, H, pad(" "..g_sMsg, W), SEL, BAR_BG); g_sMsg = ""
    else
        local nF, nD = 0, 0
        for i = 1, g_nEnt do
            if g_tEnt[i].iType == 2 then nD = nD+1 else nF = nF+1 end
        end
        local sMem = string.format("Mem:%dKB", math.floor(computer.freeMemory()/1024))
        local sKeys = g_sPreview
            and " Up/Dn:Scroll  H:Hex  Esc:Back  Q:Quit"
            or  " Arrows Tab /:Find P:Preview D:Drives R:Refresh Q:Quit"
        local sR = string.format(" %dF %dD  %s  %d/%d ", nF, nD, sMem, g_nTSel, g_nTree)
        local nP = math.max(0, W - #sKeys - #sR)
        bp(1, H, pad(sKeys..string.rep(" ", nP)..sR, W), BAR_FG, BAR_BG)
    end

    bFlush()
end

-- =============================================
-- INPUT: SEARCH
-- =============================================

local function handleSearch(k)
    if k == "\27" then g_bSrchMode = false; g_sSrchBuf = ""; return end
    if k == "\n" then
        g_bSrchMode = false
        g_sSearch = (#g_sSrchBuf > 0) and g_sSrchBuf:lower() or nil
        g_sSrchBuf = ""
        buildTree(); g_nTSel = 1; g_nTTop = 0; loadEntries()
        return
    end
    if k == "\b" then
        if #g_sSrchBuf > 0 then g_sSrchBuf = g_sSrchBuf:sub(1,-2)
        else g_bSrchMode = false end
        return
    end
    if #k == 1 and k:byte() >= 32 and k:byte() < 127 then
        g_sSrchBuf = g_sSrchBuf .. k
    end
end

-- =============================================
-- INPUT: PARTITION SELECTOR
-- =============================================

local function handleParts(k)
    if k == "\3" or k == "q" or k == "Q" then g_bRun = false; return end
    if k == "\27[A" then g_nPartSel = math.max(1, g_nPartSel - 1) end
    if k == "\27[B" then g_nPartSel = math.min(#g_tParts, g_nPartSel + 1) end
    if k == "\27[5~" then g_nPartSel = math.max(1, g_nPartSel - (H-7)) end
    if k == "\27[6~" then g_nPartSel = math.min(#g_tParts, g_nPartSel + (H-7)) end
    if k == "r" or k == "R" then
        g_tParts = scanPartitions(); g_nPartSel = 1; g_nPartTop = 0
        g_sMsg = "Rescanned — " .. #g_tParts .. " partition(s)"
    end
    if (k == "\n" or k == "\27[C") and #g_tParts > 0 then
        local bOk, sErr = mountPart(g_tParts[g_nPartSel])
        if bOk then
            g_sPage = "browse"
            g_tExpDir = {["/"] = true}
            g_nTSel = 1; g_nTTop = 0
            g_bTFocus = true; g_sSearch = nil
            buildTree(); loadEntries()
            g_sMsg = "Mounted " .. g_sVolLbl
        else
            g_sMsg = "Mount failed: " .. tostring(sErr)
        end
    end
end

-- =============================================
-- INPUT: BROWSE
-- =============================================

local function handleBrowse(k)
    if k == "\3" or k == "q" or k == "Q" then g_bRun = false; return end

    if k == "\t" then
        if g_sPreview then g_sPreview = nil
        else g_bTFocus = not g_bTFocus end; return
    end

    if k == "d" or k == "D" then
        closeVol(); g_sPage = "parts"
        g_tParts = scanPartitions(); g_nPartSel = 1; g_nPartTop = 0; return
    end

    if k == "/" then g_bSrchMode = true; g_sSrchBuf = ""; return end

    if k == "r" or k == "R" or k == "\27[15~" then
        g_sSearch = nil; buildTree(); loadEntries(); g_sMsg = "Refreshed"; return
    end

    -- Info shortcut
    if k == "i" or k == "I" then
        if not g_bTFocus and g_nESel >= 1 and g_nESel <= g_nEnt then
            local sP = entryPath(g_nESel)
            if sP and g_oVol then
                local tS = g_oVol:stat(sP)
                if tS then
                    local sF = ""
                    if bit32.band(tS.flags or 0, 0x01) ~= 0 then sF = sF .. "inline " end
                    if bit32.band(tS.flags or 0, 0x04) ~= 0 then sF = sF .. "crc " end
                    g_sMsg = string.format("inode=%d  %s  %s  mode=0x%03X  extents=%d  %s",
                        tS.inode or 0,
                        tS.iType == 2 and "DIR" or (tS.iType == 3 and "LINK" or "FILE"),
                        fmtSz(tS.size or 0), tS.mode or 0, tS.nExtents or 0, sF)
                end
            end
        end
        return
    end

    -- Preview handling
    if g_sPreview then
        if k == "\27[A" then g_nPrevTop = math.max(0, g_nPrevTop - 1)
        elseif k == "\27[B" then g_nPrevTop = g_nPrevTop + 1
        elseif k == "\27[5~" then g_nPrevTop = math.max(0, g_nPrevTop - BH)
        elseif k == "\27[6~" then g_nPrevTop = g_nPrevTop + BH
        elseif k == "\27[H" then g_nPrevTop = 0
        elseif k == "h" or k == "H" then g_bHex = not g_bHex
        elseif k == "p" or k == "P" or k == "\27" or k == "\27[D" then
            g_sPreview = nil
        end
        return
    end

    -- Hex toggle
    if k == "h" or k == "H" then g_bHex = not g_bHex; return end

    if g_bTFocus then
        -- ---- TREE NAVIGATION ----
        if k == "\27[A" then
            g_nTSel = math.max(1, g_nTSel - 1); loadEntries()
        elseif k == "\27[B" then
            g_nTSel = math.min(g_nTree, g_nTSel + 1); loadEntries()
        elseif k == "\27[C" or k == "\n" then
            if g_nTSel >= 1 and g_nTSel <= g_nTree then
                local t = g_tTree[g_nTSel]
                if not t[5] then
                    g_tExpDir[t[3]] = true; buildTree(); loadEntries()
                else
                    g_bTFocus = false
                end
            end
        elseif k == "\27[D" then
            if g_nTSel >= 1 and g_nTSel <= g_nTree then
                local t = g_tTree[g_nTSel]
                if t[5] then
                    g_tExpDir[t[3]] = nil; buildTree(); loadEntries()
                elseif g_nTSel > 1 then
                    local d = t[1]
                    for i = g_nTSel-1, 1, -1 do
                        if g_tTree[i][1] < d then
                            g_nTSel = i; loadEntries(); break
                        end
                    end
                end
            end
        elseif k == "\b" then
            if g_nTSel >= 1 and g_nTSel <= g_nTree and g_tTree[g_nTSel][1] > 0 then
                local d = g_tTree[g_nTSel][1]
                for i = g_nTSel-1, 1, -1 do
                    if g_tTree[i][1] < d then g_nTSel = i; loadEntries(); break end
                end
            end
        elseif k == "\27[5~" then g_nTSel = math.max(1, g_nTSel - BH); loadEntries()
        elseif k == "\27[6~" then g_nTSel = math.min(g_nTree, g_nTSel + BH); loadEntries()
        elseif k == "\27[H" then g_nTSel = 1; g_nTTop = 0; loadEntries()
        elseif k == "\27[F" then g_nTSel = g_nTree; loadEntries()
        end

    else
        -- ---- ENTRY NAVIGATION ----
        if k == "\27[A" then
            g_nESel = math.max(1, g_nESel - 1)
        elseif k == "\27[B" then
            g_nESel = math.min(g_nEnt, g_nESel + 1)
        elseif k == "\27[D" then
            g_bTFocus = true
        elseif k == "\27[C" or k == "\n" then
            if g_nESel >= 1 and g_nESel <= g_nEnt then
                local ent = g_tEnt[g_nESel]
                if ent.iType == 2 then
                    local sP = entryPath(g_nESel)
                    if sP then
                        g_tExpDir[sP] = true; buildTree()
                        for i = 1, g_nTree do
                            if g_tTree[i][3] == sP then g_nTSel = i; break end
                        end
                        loadEntries(); g_bTFocus = true
                    end
                else
                    local sP = entryPath(g_nESel)
                    if sP then loadPreview(sP) end
                end
            end
        elseif k == "p" or k == "P" then
            if g_nESel >= 1 and g_nESel <= g_nEnt and g_tEnt[g_nESel].iType ~= 2 then
                local sP = entryPath(g_nESel)
                if sP then loadPreview(sP) end
            end
        elseif k == "\27[5~" then
            g_nESel = math.max(1, g_nESel - math.max(1, BH-2))
        elseif k == "\27[6~" then
            g_nESel = math.min(g_nEnt, g_nESel + math.max(1, BH-2))
        elseif k == "\27[H" then g_nESel = 1; g_nETop = 0
        elseif k == "\27[F" then g_nESel = g_nEnt
        elseif k == "\b" then g_bTFocus = true
        end
    end
end

-- =============================================
-- MAIN
-- =============================================

local function main()
    fs.deviceControl(hIn, "enter_alt_screen", {})
    gFill(1, 1, W, H, FG, BG)

    -- Auto-open device from command line
    if args[1] and args[1]:find("/dev/", 1, true) then
        local sPath = args[1]
        local hD = fs.open(sPath, "r")
        if hD then
            fs.close(hD)
            g_tParts = scanPartitions()
            -- Filter to this device only
            local tF = {}
            for _, p in ipairs(g_tParts) do
                if p.sDevPath == sPath then tF[#tF+1] = p end
            end
            if #tF == 1 then
                local bOk, sErr = mountPart(tF[1])
                if bOk then
                    g_sPage = "browse"
                    g_tExpDir = {["/"] = true}
                    buildTree(); loadEntries()
                    g_sMsg = "Mounted " .. g_sVolLbl
                else
                    g_tParts = tF; g_sMsg = "Mount failed: " .. tostring(sErr)
                end
            elseif #tF > 1 then
                g_tParts = tF
            else
                g_tParts = scanPartitions()
                g_sMsg = "No AXFS partitions on " .. sPath
            end
        else
            g_tParts = scanPartitions()
            g_sMsg = "Cannot open " .. sPath
        end
    else
        g_tParts = scanPartitions()
    end

    while g_bRun do
        if g_sPage == "parts" then
            renderParts()
        else
            renderBrowse()
        end

        local k = fs.read(hIn)
        if not k then g_bRun = false
        elseif g_bSrchMode then handleSearch(k)
        elseif g_sPage == "parts" then handleParts(k)
        else handleBrowse(k) end
    end
end

local ok, err = pcall(main)

closeVol()
fs.deviceControl(hIn, "leave_alt_screen", {})
fs.deviceControl(hIn, "set_mode", {"cooked"})
fs.close(hIn)
if not ok then print("axplorer: " .. tostring(err)) end