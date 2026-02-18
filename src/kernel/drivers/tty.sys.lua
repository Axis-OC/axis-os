--
-- /drivers/tty.sys.lua
-- v5.1: Color-Tracked Scrollback
-- PgUp/PgDn, Mouse Wheel, Home/End — with full color preservation.
--

local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

g_tDriverInfo = {
  sDriverName = "AxisTTY",
  sDriverType = tDKStructs.DRIVER_TYPE_KMD,
  nLoadPriority = 100,
  sVersion = "5.1.0",
}

local g_pDeviceObject = nil
local g_oGpuProxy = nil
local g_tDispatchTable = nil

local SCROLLBACK_MAX    = 500
local SCROLL_WHEEL_STEP = 3
local DEFAULT_FG = 0xFFFFFF
local DEFAULT_BG = 0x000000

local tAnsiColors = {
  [30] = 0x000000, [31] = 0xFF0000, [32] = 0x00FF00, [33] = 0xFFFF00,
  [34] = 0x0000FF, [35] = 0xFF00FF, [36] = 0x00FFFF, [37] = 0xFFFFFF,
  [90] = 0x555555,
}

-- =============================================
-- 1. SHADOW BUFFER WITH PER-CELL COLOR
--
-- Live screen:
--   tScreenRows[y] = text string
--   tScreenFg[y]   = { [x]=fgColor, ... }  (sparse, nil=DEFAULT_FG)
--   tScreenBg[y]   = { [x]=bgColor, ... }  (sparse, nil=DEFAULT_BG)
--
-- Scrollback history:
--   tScrollback[n]   = text string
--   tScrollbackFg[n] = { [x]=fgColor, ... }
--   tScrollbackBg[n] = { [x]=bgColor, ... }
--
-- Current write colors:
--   nCurrentFg, nCurrentBg
-- =============================================

local function fInitBuffers(pExt)
  pExt.tScreenRows = {}
  pExt.tScreenFg   = {}
  pExt.tScreenBg   = {}
  for y = 1, pExt.nHeight do
    pExt.tScreenRows[y] = string.rep(" ", pExt.nWidth)
    pExt.tScreenFg[y]   = {}
    pExt.tScreenBg[y]   = {}
  end
  pExt.tScrollback   = {}
  pExt.tScrollbackFg = {}
  pExt.tScrollbackBg = {}
  pExt.nScrollOffset = 0
  pExt.nCurrentFg    = DEFAULT_FG
  pExt.nCurrentBg    = DEFAULT_BG
end

-- record the current fg/bg into the color maps for a range of cells
local function fRecordColors(pExt, nY, nStartX, nCount)
  if nY < 1 or nY > pExt.nHeight then return end
  local tFg = pExt.tScreenFg[nY]
  local tBg = pExt.tScreenBg[nY]
  if not tFg then tFg = {}; pExt.tScreenFg[nY] = tFg end
  if not tBg then tBg = {}; pExt.tScreenBg[nY] = tBg end
  local fg, bg = pExt.nCurrentFg, pExt.nCurrentBg
  local nEnd = math.min(nStartX + nCount - 1, pExt.nWidth)
  for x = nStartX, nEnd do
    tFg[x] = fg
    tBg[x] = bg
  end
end

-- update the text shadow for a range
local function fUpdateShadow(pExt, nX, nY, sText)
  if nY < 1 or nY > pExt.nHeight then return end
  local sRow = pExt.tScreenRows[nY]
  if not sRow then sRow = string.rep(" ", pExt.nWidth) end
  if #sRow < pExt.nWidth then
    sRow = sRow .. string.rep(" ", pExt.nWidth - #sRow)
  end
  local nEnd = math.min(nX + #sText - 1, pExt.nWidth)
  local nLen = nEnd - nX + 1
  if nLen <= 0 then return end
  local sBefore = (nX > 1) and sRow:sub(1, nX - 1) or ""
  local sAfter  = (nEnd < pExt.nWidth) and sRow:sub(nEnd + 1) or ""
  pExt.tScreenRows[nY] = sBefore .. sText:sub(1, nLen) .. sAfter
end

-- =============================================
-- 2. COLOR-AWARE RENDERING
-- Renders one row to the GPU using stored color info.
-- Groups consecutive same-color cells into single gpu.set calls.
-- =============================================

local function fRenderRow(nScreenY, sText, tFg, tBg, nWidth)
  if not g_oGpuProxy then return end
  if not sText then sText = "" end
  if #sText < nWidth then sText = sText .. string.rep(" ", nWidth - #sText) end

  local nLastSetFg, nLastSetBg = -1, -1
  local nX = 1

  while nX <= nWidth do
    local nFg = (tFg and tFg[nX]) or DEFAULT_FG
    local nBg = (tBg and tBg[nX]) or DEFAULT_BG

    -- find how far this color run extends
    local nRunEnd = nX
    while nRunEnd < nWidth do
      local nNFg = (tFg and tFg[nRunEnd + 1]) or DEFAULT_FG
      local nNBg = (tBg and tBg[nRunEnd + 1]) or DEFAULT_BG
      if nNFg ~= nFg or nNBg ~= nBg then break end
      nRunEnd = nRunEnd + 1
    end

    -- only call GPU color setters when the color actually changes
    if nFg ~= nLastSetFg then g_oGpuProxy.setForeground(nFg); nLastSetFg = nFg end
    if nBg ~= nLastSetBg then g_oGpuProxy.setBackground(nBg); nLastSetBg = nBg end
    g_oGpuProxy.set(nX, nScreenY, sText:sub(nX, nRunEnd))

    nX = nRunEnd + 1
  end
end

-- =============================================
-- 3. SCROLL ENGINE
-- =============================================

local function scroll(pExt)
  if not g_oGpuProxy then return end
  -- push top row (text + colors) into history
  table.insert(pExt.tScrollback,   pExt.tScreenRows[1] or "")
  table.insert(pExt.tScrollbackFg, pExt.tScreenFg[1]   or {})
  table.insert(pExt.tScrollbackBg, pExt.tScreenBg[1]   or {})

  if #pExt.tScrollback > SCROLLBACK_MAX then
    table.remove(pExt.tScrollback,   1)
    table.remove(pExt.tScrollbackFg, 1)
    table.remove(pExt.tScrollbackBg, 1)
    if pExt.nScrollOffset > #pExt.tScrollback then
      pExt.nScrollOffset = #pExt.tScrollback
    end
  end

  -- shift live rows up
  for y = 1, pExt.nHeight - 1 do
    pExt.tScreenRows[y] = pExt.tScreenRows[y + 1]
    pExt.tScreenFg[y]   = pExt.tScreenFg[y + 1]
    pExt.tScreenBg[y]   = pExt.tScreenBg[y + 1]
  end
  pExt.tScreenRows[pExt.nHeight] = string.rep(" ", pExt.nWidth)
  pExt.tScreenFg[pExt.nHeight]   = {}
  pExt.tScreenBg[pExt.nHeight]   = {}

  -- hardware scroll only when viewing live
  if pExt.nScrollOffset == 0 then
    g_oGpuProxy.copy(1, 2, pExt.nWidth, pExt.nHeight - 1, 0, -1)
    g_oGpuProxy.fill(1, pExt.nHeight, pExt.nWidth, 1, " ")
  end
  pExt.nCursorY = pExt.nHeight
end

-- redraw the entire screen from scrollback + live at current offset
local function fRenderViewport(pExt)
  if not g_oGpuProxy then return end
  local nSbLen = #pExt.tScrollback
  local nTotal = nSbLen + pExt.nHeight
  local nStart = nTotal - pExt.nHeight - pExt.nScrollOffset + 1
  if nStart < 1 then nStart = 1 end

  for screenY = 1, pExt.nHeight do
    local nVirt = nStart + screenY - 1
    local sLine, tFg, tBg
    if nVirt <= nSbLen then
      sLine = pExt.tScrollback[nVirt]
      tFg   = pExt.tScrollbackFg[nVirt]
      tBg   = pExt.tScrollbackBg[nVirt]
    else
      local nLiveY = nVirt - nSbLen
      sLine = pExt.tScreenRows[nLiveY]
      tFg   = pExt.tScreenFg[nLiveY]
      tBg   = pExt.tScreenBg[nLiveY]
    end
    fRenderRow(screenY, sLine, tFg, tBg, pExt.nWidth)
  end

  -- scroll indicator
  if pExt.nScrollOffset > 0 then
    local sInd = string.format(" [-%d lines] PgUp/PgDn ", pExt.nScrollOffset)
    if #sInd > pExt.nWidth then sInd = sInd:sub(1, pExt.nWidth) end
    local nIndX = pExt.nWidth - #sInd + 1
    if nIndX < 1 then nIndX = 1 end
    g_oGpuProxy.setForeground(0x000000)
    g_oGpuProxy.setBackground(0xFFFF00)
    g_oGpuProxy.set(nIndX, pExt.nHeight, sInd)
  end
end

-- restore the live screen with colors
local function fRenderLive(pExt)
  if not g_oGpuProxy then return end
  for y = 1, pExt.nHeight do
    fRenderRow(y, pExt.tScreenRows[y], pExt.tScreenFg[y], pExt.tScreenBg[y], pExt.nWidth)
  end
  -- restore the current write colors so new output uses the right ones
  g_oGpuProxy.setForeground(pExt.nCurrentFg)
  g_oGpuProxy.setBackground(pExt.nCurrentBg)
end

local function fScrollUp(pExt, nLines)
  local nMax = #pExt.tScrollback
  if nMax == 0 then return end
  pExt.nScrollOffset = math.min(pExt.nScrollOffset + nLines, nMax)
  fRenderViewport(pExt)
end

local function fScrollDown(pExt, nLines)
  if pExt.nScrollOffset <= 0 then return end
  pExt.nScrollOffset = math.max(pExt.nScrollOffset - nLines, 0)
  if pExt.nScrollOffset == 0 then
    fRenderLive(pExt)
  else
    fRenderViewport(pExt)
  end
end

local function fSnapToBottom(pExt)
  if pExt.nScrollOffset > 0 then
    pExt.nScrollOffset = 0
    fRenderLive(pExt)
  end
end

-- =============================================
-- 4. WRITE ENGINE (color-tracked)
-- =============================================

local function rawWrite(pExt, sText)
  if #sText == 0 then return end
  local nLen   = #sText
  local nSpace = pExt.nWidth - pExt.nCursorX + 1

  if nLen <= nSpace then
    fRecordColors(pExt, pExt.nCursorY, pExt.nCursorX, nLen)
    fUpdateShadow(pExt, pExt.nCursorX, pExt.nCursorY, sText)
    if pExt.nScrollOffset == 0 and g_oGpuProxy then
      g_oGpuProxy.set(pExt.nCursorX, pExt.nCursorY, sText)
    end
    pExt.nCursorX = pExt.nCursorX + nLen
    if pExt.nCursorX > pExt.nWidth then
      pExt.nCursorX = 1
      if pExt.nCursorY < pExt.nHeight then
        pExt.nCursorY = pExt.nCursorY + 1
      else
        scroll(pExt)
      end
    end
  else
    local sPart = string.sub(sText, 1, nSpace)
    fRecordColors(pExt, pExt.nCursorY, pExt.nCursorX, nSpace)
    fUpdateShadow(pExt, pExt.nCursorX, pExt.nCursorY, sPart)
    if pExt.nScrollOffset == 0 and g_oGpuProxy then
      g_oGpuProxy.set(pExt.nCursorX, pExt.nCursorY, sPart)
    end
    pExt.nCursorX = 1
    if pExt.nCursorY < pExt.nHeight then
      pExt.nCursorY = pExt.nCursorY + 1
    else
      scroll(pExt)
    end
    rawWrite(pExt, string.sub(sText, nSpace + 1))
  end
end

local function writeToScreen(pDeviceObject, sData)
  if not g_oGpuProxy then return end
  local pExt = pDeviceObject.pDeviceExtension
  local sStr = tostring(sData)

  if not sStr:find("[%c\27]") then
    pcall(rawWrite, pExt, sStr)
    return
  end

  local nLen = #sStr
  local nIdx = 1

  while nIdx <= nLen do
    local nNext = string.find(sStr, "[%c\27]", nIdx)
    if not nNext then
      pcall(rawWrite, pExt, string.sub(sStr, nIdx))
      break
    end
    if nNext > nIdx then
      pcall(rawWrite, pExt, string.sub(sStr, nIdx, nNext - 1))
    end

    local nByte = string.byte(sStr, nNext)
    pcall(function()
      if nByte == 10 then -- \n
        pExt.nCursorX = 1
        if pExt.nCursorY < pExt.nHeight then
          pExt.nCursorY = pExt.nCursorY + 1
        else
          scroll(pExt)
        end
        nIdx = nNext + 1

      elseif nByte == 13 then -- \r
        pExt.nCursorX = 1
        nIdx = nNext + 1

      elseif nByte == 8 then -- \b
        if pExt.nCursorX > 1 then
          pExt.nCursorX = pExt.nCursorX - 1
          fUpdateShadow(pExt, pExt.nCursorX, pExt.nCursorY, " ")
          if pExt.tScreenFg[pExt.nCursorY] then
            pExt.tScreenFg[pExt.nCursorY][pExt.nCursorX] = nil
          end
          if pExt.tScreenBg[pExt.nCursorY] then
            pExt.tScreenBg[pExt.nCursorY][pExt.nCursorX] = nil
          end
          if pExt.nScrollOffset == 0 then
            g_oGpuProxy.set(pExt.nCursorX, pExt.nCursorY, " ")
          end
        end
        nIdx = nNext + 1

      elseif nByte == 12 then -- \f  (clear screen)
        for y = 1, pExt.nHeight do
          pExt.tScreenRows[y] = string.rep(" ", pExt.nWidth)
          pExt.tScreenFg[y]   = {}
          pExt.tScreenBg[y]   = {}
        end
        pExt.nScrollOffset = 0
        pExt.nCurrentFg = DEFAULT_FG
        pExt.nCurrentBg = DEFAULT_BG
        g_oGpuProxy.setForeground(DEFAULT_FG)
        g_oGpuProxy.setBackground(DEFAULT_BG)
        g_oGpuProxy.fill(1, 1, pExt.nWidth, pExt.nHeight, " ")
        pExt.nCursorX, pExt.nCursorY = 1, 1
        nIdx = nNext + 1

      elseif nByte == 27 then -- ESC
        if string.sub(sStr, nNext + 1, nNext + 1) == "[" then
          local nEnd = string.find(sStr, "[a-zA-Z]", nNext + 2)
          if nEnd and (nEnd - nNext) < 20 then
            local sCmd   = string.sub(sStr, nEnd, nEnd)
            local sParam = string.sub(sStr, nNext + 2, nEnd - 1)
            local tP = {}
            for sVal in string.gmatch(sParam, "%d+") do
              table.insert(tP, tonumber(sVal))
            end

            if sCmd == "m" then
              local bAny = false
              for _, n in ipairs(tP) do
                if tAnsiColors[n] then
                  pExt.nCurrentFg = tAnsiColors[n]
                  bAny = true
                elseif n == 0 then
                  pExt.nCurrentFg = DEFAULT_FG
                  pExt.nCurrentBg = DEFAULT_BG
                  bAny = true
                end
              end
              if not bAny and #tP == 0 then
                pExt.nCurrentFg = DEFAULT_FG
                pExt.nCurrentBg = DEFAULT_BG
              end
              -- apply to GPU only when live
              if pExt.nScrollOffset == 0 then
                g_oGpuProxy.setForeground(pExt.nCurrentFg)
                g_oGpuProxy.setBackground(pExt.nCurrentBg)
              end

            elseif sCmd == "H" or sCmd == "f" then
              pExt.nCursorY = math.max(1, math.min(pExt.nHeight, tP[1] or 1))
              pExt.nCursorX = math.max(1, math.min(pExt.nWidth,  tP[2] or 1))

            elseif sCmd == "J" then
              if tP[1] == 2 then
                for y = 1, pExt.nHeight do
                  pExt.tScreenRows[y] = string.rep(" ", pExt.nWidth)
                  pExt.tScreenFg[y]   = {}
                  pExt.tScreenBg[y]   = {}
                end
                if pExt.nScrollOffset == 0 then
                  g_oGpuProxy.fill(1, 1, pExt.nWidth, pExt.nHeight, " ")
                end
                pExt.nCursorX, pExt.nCursorY = 1, 1
              end

            elseif sCmd == "A" then
              pExt.nCursorY = math.max(1, pExt.nCursorY - (tP[1] or 1))
            elseif sCmd == "B" then
              pExt.nCursorY = math.min(pExt.nHeight, pExt.nCursorY + (tP[1] or 1))
            elseif sCmd == "C" then
              pExt.nCursorX = math.min(pExt.nWidth, pExt.nCursorX + (tP[1] or 1))
            elseif sCmd == "D" then
              pExt.nCursorX = math.max(1, pExt.nCursorX - (tP[1] or 1))
            end

            nIdx = nEnd + 1
            nNext = nEnd
          else
            nIdx = nNext + 1
          end
        else
          nIdx = nNext + 1
        end
      else
        nIdx = nNext + 1
      end
    end)

    if nIdx <= nNext then nIdx = nNext + 1 end
  end
end

-- =============================================
-- 5. KEY PROCESSING
-- =============================================

local function processKeyCooked(ext, ch, code)
  -- scroll keys work always, even mid-input
  if code == 201 then -- PgUp
    fScrollUp(ext, math.max(1, math.floor(ext.nHeight / 2)))
    return true
  elseif code == 209 then -- PgDn
    fScrollDown(ext, math.max(1, math.floor(ext.nHeight / 2)))
    return true
  elseif code == 199 then -- Home
    fScrollUp(ext, #ext.tScrollback)
    return true
  elseif code == 207 then -- End
    fSnapToBottom(ext)
    return true
  end

  -- any other key while scrolled: snap to live first
  fSnapToBottom(ext)

  if not ext.pPendingReadIrp then return false end

  if code == 28 then -- Enter
    local sResult = ext.sLineBuffer or ""
    local pIrp = ext.pPendingReadIrp
    ext.pPendingReadIrp = nil
    ext.sLineBuffer = ""
    oKMD.DkCompleteRequest(pIrp, 0, sResult)
    writeToScreen(g_pDeviceObject, "\n")
    return true

  elseif code == 14 then -- Backspace
    if ext.sLineBuffer and #ext.sLineBuffer > 0 then
      ext.sLineBuffer = ext.sLineBuffer:sub(1, -2)
      writeToScreen(g_pDeviceObject, "\b")
    end
    return true

  elseif code == 15 then -- Tab
    local sResult = "\t" .. (ext.sLineBuffer or "")
    local pIrp = ext.pPendingReadIrp
    ext.pPendingReadIrp = nil
    ext.sLineBuffer = ""
    oKMD.DkCompleteRequest(pIrp, 0, sResult)
    return true

  elseif code == 46 and ch == 3 then -- Ctrl+C
    local pIrp = ext.pPendingReadIrp
    if pIrp then
      ext.pPendingReadIrp = nil
      ext.sLineBuffer = ""
      oKMD.DkCompleteRequest(pIrp, 0, "\3")
      writeToScreen(g_pDeviceObject, "^C\n")
    end
    return true

  elseif code == 200 then -- Up arrow
    local sResult = "\27[A" .. (ext.sLineBuffer or "")
    local pIrp = ext.pPendingReadIrp
    ext.pPendingReadIrp = nil
    ext.sLineBuffer = ""
    oKMD.DkCompleteRequest(pIrp, 0, sResult)
    return true

  elseif code == 208 then -- Down arrow
    local sResult = "\27[B" .. (ext.sLineBuffer or "")
    local pIrp = ext.pPendingReadIrp
    ext.pPendingReadIrp = nil
    ext.sLineBuffer = ""
    oKMD.DkCompleteRequest(pIrp, 0, sResult)
    return true

  elseif code ~= 0 and ch > 0 and ch < 256 then
    local s = string.char(ch)
    ext.sLineBuffer = (ext.sLineBuffer or "") .. s
    writeToScreen(g_pDeviceObject, s)
    return true
  end

  return false
end

local function processKeyRaw(ext, ch, code)
  if not ext.pPendingReadIrp then return false end
  local sResult = nil

  if code == 28 then      sResult = "\n"       -- Enter
  elseif code == 14 then  sResult = "\b"       -- Backspace
  elseif code == 15 then  sResult = "\t"       -- Tab
  elseif code == 1 then   sResult = "\27"      -- Escape
  elseif code == 200 then sResult = "\27[A"    -- Up
  elseif code == 208 then sResult = "\27[B"    -- Down
  elseif code == 203 then sResult = "\27[D"    -- Left
  elseif code == 205 then sResult = "\27[C"    -- Right
  elseif code == 201 then sResult = "\27[5~"   -- PgUp
  elseif code == 209 then sResult = "\27[6~"   -- PgDn
  elseif code == 199 then sResult = "\27[H"    -- Home
  elseif code == 207 then sResult = "\27[F"    -- End
  elseif code == 46 and ch == 3 then sResult = "\3" -- Ctrl+C
  elseif code == 59 then  sResult = "\27[11~"  -- F1
  elseif code == 60 then  sResult = "\27[12~"  -- F2
  elseif code == 61 then  sResult = "\27[13~"  -- F3
  elseif code == 62 then  sResult = "\27[14~"  -- F4
  elseif code == 63 then  sResult = "\27[15~"  -- F5
  elseif ch > 0 and ch < 256 then
    sResult = string.char(ch)
  end

  if sResult then
    local pIrp = ext.pPendingReadIrp
    ext.pPendingReadIrp = nil
    oKMD.DkCompleteRequest(pIrp, 0, sResult)
    return true
  end
  return false
end

-- =============================================
-- 6. IRP HANDLERS
-- =============================================

local function fCreate(d, i) oKMD.DkCompleteRequest(i, 0, 0) end
local function fClose(d, i)  oKMD.DkCompleteRequest(i, 0)    end

local function fWrite(d, i)
  writeToScreen(d, i.tParameters.sData)
  oKMD.DkCompleteRequest(i, 0, #i.tParameters.sData)
end

local function fRead(d, i)
  local p = d.pDeviceExtension
  if p.pPendingReadIrp then
    oKMD.DkCompleteRequest(i, tStatus.STATUS_DEVICE_BUSY)
  else
    p.pPendingReadIrp = i
    if p.sLineBuffer == nil then p.sLineBuffer = "" end
    local sMode = p.sMode or "cooked"
    while p.tKeyBuffer and #p.tKeyBuffer > 0 and p.pPendingReadIrp do
      local tKey = table.remove(p.tKeyBuffer, 1)
      if sMode == "raw" then
        processKeyRaw(p, tKey[1], tKey[2])
      else
        processKeyCooked(p, tKey[1], tKey[2])
      end
    end
  end
end

local function fDeviceControl(d, i)
  local ext = d.pDeviceExtension
  local sMethod = i.tParameters.sMethod
  local tArgs = i.tParameters.tArgs or {}

  if sMethod == "set_buffer" then
    ext.sLineBuffer = tArgs[1] or ""
    oKMD.DkCompleteRequest(i, 0)
  elseif sMethod == "get_buffer" then
    oKMD.DkCompleteRequest(i, 0, ext.sLineBuffer or "")
  elseif sMethod == "get_cursor" then
    oKMD.DkCompleteRequest(i, 0, {x = ext.nCursorX, y = ext.nCursorY})
  elseif sMethod == "scroll_up" then
    fScrollUp(ext, tArgs[1] or math.floor(ext.nHeight / 2))
    oKMD.DkCompleteRequest(i, 0)
  elseif sMethod == "scroll_down" then
    fScrollDown(ext, tArgs[1] or math.floor(ext.nHeight / 2))
    oKMD.DkCompleteRequest(i, 0)
  elseif sMethod == "scroll_end" then
    fSnapToBottom(ext)
    oKMD.DkCompleteRequest(i, 0)
    elseif sMethod == "set_mode" then
    local sNewMode = tArgs[1]
    if sNewMode == "raw" or sNewMode == "cooked" then
      ext.sMode = sNewMode
      ext.sLineBuffer = ""
      oKMD.DkCompleteRequest(i, 0)
    else
      oKMD.DkCompleteRequest(i, tStatus.STATUS_INVALID_PARAMETER)
    end
  elseif sMethod == "get_mode" then
    oKMD.DkCompleteRequest(i, 0, ext.sMode or "cooked")
  elseif sMethod == "get_size" then
    oKMD.DkCompleteRequest(i, 0, {w = ext.nWidth, h = ext.nHeight})
  elseif sMethod == "get_scroll_info" then
    oKMD.DkCompleteRequest(i, 0, {
      offset = ext.nScrollOffset,
      max    = #ext.tScrollback,
      height = ext.nHeight,
    })
  else
    oKMD.DkCompleteRequest(i, tStatus.STATUS_NOT_IMPLEMENTED)
  end
end

-- =============================================
-- 7. DRIVER ENTRY
-- =============================================

function DriverEntry(pObj)
  oKMD.DkPrint("AxisTTY v5.1 Color Scrollback Loaded.")
  pObj.tDispatch[tDKStructs.IRP_MJ_CREATE]         = fCreate
  pObj.tDispatch[tDKStructs.IRP_MJ_CLOSE]          = fClose
  pObj.tDispatch[tDKStructs.IRP_MJ_WRITE]          = fWrite
  pObj.tDispatch[tDKStructs.IRP_MJ_READ]           = fRead
  pObj.tDispatch[tDKStructs.IRP_MJ_DEVICE_CONTROL] = fDeviceControl
  g_tDispatchTable = pObj.tDispatch

  local st, dev = oKMD.DkCreateDevice(pObj, "\\Device\\TTY0")
  if st ~= 0 then return st end
  g_pDeviceObject = dev
  oKMD.DkCreateSymbolicLink("/dev/tty", "\\Device\\TTY0")

  local gpu, scr
  local b, l
  b, l = syscall("raw_component_list", "gpu")
  if b and l then for k in pairs(l) do gpu = k; break end end
  b, l = syscall("raw_component_list", "screen")
  if b and l then for k in pairs(l) do scr = k; break end end

  dev.pDeviceExtension.nWidth      = 80
  dev.pDeviceExtension.nHeight     = 25
  dev.pDeviceExtension.nCursorX    = 1
  dev.pDeviceExtension.nCursorY    = 25
  dev.pDeviceExtension.tKeyBuffer  = {}
  dev.pDeviceExtension.sLineBuffer = ""
  dev.pDeviceExtension.sMode = "cooked"

  if gpu then
    local _, p = oKMD.DkGetHardwareProxy(gpu)
    g_oGpuProxy = p
    if scr and p then
      p.bind(scr)
      local w, h = p.getResolution()
      p.setBackground(DEFAULT_BG)
      p.setForeground(DEFAULT_FG)
      if w and h then
        dev.pDeviceExtension.nWidth   = w
        dev.pDeviceExtension.nHeight  = h
        dev.pDeviceExtension.nCursorY = h
      end
    end
  end

  fInitBuffers(dev.pDeviceExtension)

  oKMD.DkRegisterInterrupt("key_down")
  oKMD.DkRegisterInterrupt("scroll")
  return 0
end

function DriverUnload() return 0 end

-- =============================================
-- 8. MAIN LOOP
-- =============================================

while true do
  local b, pid, sig, p1, p2, p3, p4, p5 = syscall("signal_pull")
  if b then

    if sig == "driver_init" then
      local s = DriverEntry(p1)
      syscall("signal_send", pid, "driver_init_complete", s, p1)

    elseif sig == "irp_dispatch" then
      local pIrp    = p1
      local fHandler = p2
      if not fHandler and g_tDispatchTable and pIrp and pIrp.nMajorFunction then
        fHandler = g_tDispatchTable[pIrp.nMajorFunction]
      end
      if fHandler then fHandler(g_pDeviceObject, pIrp) end

    elseif sig == "hardware_interrupt" and p1 == "key_down" then
      local ext = g_pDeviceObject and g_pDeviceObject.pDeviceExtension
      if ext then
        local ch, code = p3, p4
        local sMode = ext.sMode or "cooked"

        if sMode == "raw" then
          -- RAW MODE: all keys go to app, mouse scroll still works for scrollback
          if ext.pPendingReadIrp then
            processKeyRaw(ext, ch, code)
          else
            if not ext.tKeyBuffer then ext.tKeyBuffer = {} end
            table.insert(ext.tKeyBuffer, {ch, code})
          end
        else
          -- COOKED MODE: scroll keys work, line editing
          if ext.pPendingReadIrp then
            processKeyCooked(ext, ch, code)
          else
            if code == 201 then
              fScrollUp(ext, math.max(1, math.floor(ext.nHeight / 2)))
            elseif code == 209 then
              fScrollDown(ext, math.max(1, math.floor(ext.nHeight / 2)))
            elseif code == 199 then
              fScrollUp(ext, #ext.tScrollback)
            elseif code == 207 then
              fSnapToBottom(ext)
            else
              fSnapToBottom(ext)
              if not ext.tKeyBuffer then ext.tKeyBuffer = {} end
              table.insert(ext.tKeyBuffer, {ch, code})
            end
          end
        end
      end

    elseif sig == "hardware_interrupt" and p1 == "scroll" then
      local ext = g_pDeviceObject and g_pDeviceObject.pDeviceExtension
      if ext and type(p2) == "number" then
        if p2 > 0 then
          fScrollUp(ext, SCROLL_WHEEL_STEP)
        else
          fScrollDown(ext, SCROLL_WHEEL_STEP)
        end
      end

    end
  end
end