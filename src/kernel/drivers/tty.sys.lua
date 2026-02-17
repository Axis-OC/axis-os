--
-- /drivers/tty.sys.lua
-- v4.6: ANSI Cursor Control Support
--

local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

g_tDriverInfo = {
  sDriverName = "AxisTTY",
  sDriverType = tDKStructs.DRIVER_TYPE_KMD,
  nLoadPriority = 100,
  sVersion = "4.6.0",
}

local g_pDeviceObject = nil
local g_oGpuProxy = nil
local g_tDispatchTable = nil


local tAnsiColors = {
  [30] = 0x000000, [31] = 0xFF0000, [32] = 0x00FF00, [33] = 0xFFFF00,
  [34] = 0x0000FF, [35] = 0xFF00FF, [36] = 0x00FFFF, [37] = 0xFFFFFF,
  [90] = 0x555555,
}

local function scroll(pExt)
  if not g_oGpuProxy then return end
  g_oGpuProxy.copy(1, 2, pExt.nWidth, pExt.nHeight - 1, 0, -1)
  g_oGpuProxy.fill(1, pExt.nHeight, pExt.nWidth, 1, " ")
  pExt.nCursorY = pExt.nHeight
end

local function safeDraw(fFunc, ...)
    local bOk, sErr = pcall(fFunc, ...)
end


local function rawWrite(pExt, sText)
  if #sText == 0 then return end
  local nLen = #sText
  local nRemainingSpace = pExt.nWidth - pExt.nCursorX + 1
  
  if nLen <= nRemainingSpace then
      g_oGpuProxy.set(pExt.nCursorX, pExt.nCursorY, sText)
      pExt.nCursorX = pExt.nCursorX + nLen
      if pExt.nCursorX > pExt.nWidth then
         pExt.nCursorX = 1
         if pExt.nCursorY < pExt.nHeight then pExt.nCursorY = pExt.nCursorY + 1 else scroll(pExt) end
      end
  else
      local sPart1 = string.sub(sText, 1, nRemainingSpace)
      g_oGpuProxy.set(pExt.nCursorX, pExt.nCursorY, sPart1)
      
      pExt.nCursorX = 1
      if pExt.nCursorY < pExt.nHeight then pExt.nCursorY = pExt.nCursorY + 1 else scroll(pExt) end
      
      rawWrite(pExt, string.sub(sText, nRemainingSpace + 1))
  end
end

local function writeToScreen(pDeviceObject, sData)
  if not g_oGpuProxy then return end
  local pExt = pDeviceObject.pDeviceExtension
  local sStr = tostring(sData)
  
  if not sStr:find("[%c\27]") then
     safeDraw(rawWrite, pExt, sStr)
     return
  end
  
  local nLen = #sStr
  local nIdx = 1
  
  while nIdx <= nLen do
      local nNextSpecial = string.find(sStr, "[%c\27]", nIdx)
      if not nNextSpecial then
          safeDraw(rawWrite, pExt, string.sub(sStr, nIdx))
          break
      end
      if nNextSpecial > nIdx then
          safeDraw(rawWrite, pExt, string.sub(sStr, nIdx, nNextSpecial - 1))
      end
      
      local nByte = string.byte(sStr, nNextSpecial)
      pcall(function()
          if nByte == 10 then -- \n
              pExt.nCursorX = 1
              if pExt.nCursorY < pExt.nHeight then pExt.nCursorY = pExt.nCursorY + 1 else scroll(pExt) end
              nIdx = nNextSpecial + 1
          elseif nByte == 13 then -- \r
              pExt.nCursorX = 1
              nIdx = nNextSpecial + 1
          elseif nByte == 8 then -- \b
              if pExt.nCursorX > 1 then
                  pExt.nCursorX = pExt.nCursorX - 1
                  g_oGpuProxy.set(pExt.nCursorX, pExt.nCursorY, " ")
              end
              nIdx = nNextSpecial + 1
          elseif nByte == 12 then -- \f
              g_oGpuProxy.fill(1, 1, pExt.nWidth, pExt.nHeight, " ")
              pExt.nCursorX, pExt.nCursorY = 1, 1
              nIdx = nNextSpecial + 1
              
          elseif nByte == 27 then
              if string.sub(sStr, nNextSpecial + 1, nNextSpecial + 1) == "[" then
                  local nEndAnsi = string.find(sStr, "[a-zA-Z]", nNextSpecial + 2)
                  
                  if nEndAnsi and (nEndAnsi - nNextSpecial) < 20 then
                      local sCmdChar = string.sub(sStr, nEndAnsi, nEndAnsi)
                      local sParamStr = string.sub(sStr, nNextSpecial + 2, nEndAnsi - 1)
                      
                      local tParams = {}
                      for sVal in string.gmatch(sParamStr, "%d+") do
                         table.insert(tParams, tonumber(sVal))
                      end
                      
                      if sCmdChar == "m" then
                          for _, nColor in ipairs(tParams) do
                              if tAnsiColors[nColor] then
                                  g_oGpuProxy.setForeground(tAnsiColors[nColor])
                              elseif nColor == 0 then
                                  g_oGpuProxy.setForeground(0xFFFFFF)
                                  g_oGpuProxy.setBackground(0x000000)
                              end
                          end
                          if #tParams == 0 then
                              g_oGpuProxy.setForeground(0xFFFFFF)
                              g_oGpuProxy.setBackground(0x000000)
                          end
                          
                      elseif sCmdChar == "H" or sCmdChar == "f" then
                          -- ESC[y;xH
                          local nY = tParams[1] or 1
                          local nX = tParams[2] or 1
                          
                          pExt.nCursorY = math.max(1, math.min(pExt.nHeight, nY))
                          pExt.nCursorX = math.max(1, math.min(pExt.nWidth, nX))
                          
                      elseif sCmdChar == "J" then
                          -- ESC[2J
                          if tParams[1] == 2 then
                             g_oGpuProxy.fill(1, 1, pExt.nWidth, pExt.nHeight, " ")
                             pExt.nCursorX, pExt.nCursorY = 1, 1
                          end
                          
                      elseif sCmdChar == "A" then -- Up
                          pExt.nCursorY = math.max(1, pExt.nCursorY - (tParams[1] or 1))
                      elseif sCmdChar == "B" then -- Down
                          pExt.nCursorY = math.min(pExt.nHeight, pExt.nCursorY + (tParams[1] or 1))
                      elseif sCmdChar == "C" then -- Right
                          pExt.nCursorX = math.min(pExt.nWidth, pExt.nCursorX + (tParams[1] or 1))
                      elseif sCmdChar == "D" then -- Left
                          pExt.nCursorX = math.max(1, pExt.nCursorX - (tParams[1] or 1))
                      end
                      
                      nIdx = nEndAnsi + 1
                      nNextSpecial = nEndAnsi
                  else
                      nIdx = nNextSpecial + 1
                  end
              else
                  nIdx = nNextSpecial + 1
              end
          else
             nIdx = nNextSpecial + 1
          end
      end)
      
      if nIdx <= nNextSpecial then nIdx = nNextSpecial + 1 end
  end
end

local function processKeyCooked(ext, ch, code)
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

-- [[ 3. IRP Handlers ]] --

local function fCreate(d, i) oKMD.DkCompleteRequest(i, 0, 0) end
local function fClose(d, i) oKMD.DkCompleteRequest(i, 0) end
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
    -- Drain any buffered keystrokes into the new read
    while p.tKeyBuffer and #p.tKeyBuffer > 0 and p.pPendingReadIrp do
      local tKey = table.remove(p.tKeyBuffer, 1)
      processKeyCooked(p, tKey[1], tKey[2])
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
  else
    oKMD.DkCompleteRequest(i, tStatus.STATUS_NOT_IMPLEMENTED)
  end
end


-- [[ 4. Driver Entry ]] --

function DriverEntry(pObj)
  oKMD.DkPrint("AxisTTY v4.6 ANSI Loaded.")
  pObj.tDispatch[tDKStructs.IRP_MJ_CREATE] = fCreate
  pObj.tDispatch[tDKStructs.IRP_MJ_CLOSE] = fClose
  pObj.tDispatch[tDKStructs.IRP_MJ_WRITE] = fWrite
  pObj.tDispatch[tDKStructs.IRP_MJ_READ] = fRead
  pObj.tDispatch[tDKStructs.IRP_MJ_DEVICE_CONTROL] = fDeviceControl
  
  g_tDispatchTable = pObj.tDispatch

  local st, dev = oKMD.DkCreateDevice(pObj, "\\Device\\TTY0")
  if st ~= 0 then return st end
  g_pDeviceObject = dev
  oKMD.DkCreateSymbolicLink("/dev/tty", "\\Device\\TTY0")
  
  local gpu, scr
  local b, l
  b, l = syscall("raw_component_list", "gpu")
  if b and l then for k in pairs(l) do gpu=k break end end
  b, l = syscall("raw_component_list", "screen")
  if b and l then for k in pairs(l) do scr=k break end end
  
  dev.pDeviceExtension.nWidth = 80
  dev.pDeviceExtension.nHeight = 25
  dev.pDeviceExtension.nCursorX = 1
  dev.pDeviceExtension.nCursorY = 25
  dev.pDeviceExtension.tKeyBuffer = {}
  dev.pDeviceExtension.sLineBuffer = ""
  
  if gpu then
     local _, p = oKMD.DkGetHardwareProxy(gpu)
     g_oGpuProxy = p
     if scr and p then
         p.bind(scr)
         local w, h = p.getResolution()
         p.setBackground(0x000000)
         p.setForeground(0xFFFFFF)
         if w and h then
             dev.pDeviceExtension.nWidth = w
             dev.pDeviceExtension.nHeight = h
             dev.pDeviceExtension.nCursorY = h
         end
     end
  end
  oKMD.DkRegisterInterrupt("key_down")
  return 0
end

function DriverUnload() return 0 end

-- [[ 5. Main Loop ]] --

while true do
  local b, pid, sig, p1, p2, p3, p4 = syscall("signal_pull")
  if b then
    if sig == "driver_init" then
        local s = DriverEntry(p1)
        syscall("signal_send", pid, "driver_init_complete", s, p1)
    elseif sig == "irp_dispatch" then
        local pIrp = p1
        local fHandler = p2
        if not fHandler and g_tDispatchTable and pIrp and pIrp.nMajorFunction then
           fHandler = g_tDispatchTable[pIrp.nMajorFunction]
        end
        if fHandler then fHandler(g_pDeviceObject, pIrp) end
    elseif sig == "hardware_interrupt" and p1 == "key_down" then
        local ext = g_pDeviceObject and g_pDeviceObject.pDeviceExtension
        if ext then
            local ch, code = p3, p4
            if ext.pPendingReadIrp then
                processKeyCooked(ext, ch, code)
            else
                if not ext.tKeyBuffer then ext.tKeyBuffer = {} end
                table.insert(ext.tKeyBuffer, {ch, code})
            end
        end
    end
  end
end