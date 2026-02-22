--
-- /lib/axfs_proxy.lua
-- AXFS proxy: makes volume look like OC managed filesystem.
-- v2: flush batching, health/stats methods
--
local AX = require("axfs_core")
local P = {}

function P.createProxy(vol, sLabel)
  local tHandles = {}
  local nNextH = 1
  local nFlushCounter = 0
  local FLUSH_INTERVAL = 8  -- flush every N close() calls

  local proxy = {
    address = "axfs-" .. (sLabel or vol.su.label or "root"),
    type = "filesystem",
    _vol = vol,
    _label = sLabel or vol.su.label or "AXFS",
  }

  function proxy.open(sPath, sMode)
    sMode = sMode or "r"
    local sClean = sPath:gsub("//", "/")
    if sClean == "" then sClean = "/" end
    if sMode == "r" then
      local data, err = vol:readFile(sClean)
      if not data then return nil, err end
      local h = nNextH; nNextH = nNextH + 1
      tHandles[h] = {path=sClean, mode="r", data=data, pos=1}
      return h
    elseif sMode == "w" then
      local h = nNextH; nNextH = nNextH + 1
      tHandles[h] = {path=sClean, mode="w", chunks={}, pos=1}
      return h
    elseif sMode == "a" then
      local existing = vol:readFile(sClean) or ""
      local h = nNextH; nNextH = nNextH + 1
      tHandles[h] = {path=sClean, mode="w", chunks={existing}, pos=#existing+1}
      return h
    else
      return nil, "Unsupported mode: " .. tostring(sMode)
    end
  end

  function proxy.read(h, nCount)
    local t = tHandles[h]
    if not t or t.mode ~= "r" then return nil end
    nCount = nCount or math.huge
    if t.pos > #t.data then return nil end
    local nEnd = math.min(t.pos + nCount - 1, #t.data)
    local s = t.data:sub(t.pos, nEnd)
    t.pos = nEnd + 1
    return #s > 0 and s or nil
  end

  function proxy.write(h, sData)
    local t = tHandles[h]
    if not t or t.mode ~= "w" then return nil end
    t.chunks[#t.chunks+1] = tostring(sData)
    return true
  end

  function proxy.close(h)
    local t = tHandles[h]
    if not t then return end
    if t.mode == "w" and #t.chunks > 0 then
      local sAll = table.concat(t.chunks)
      -- Ensure parent directories
      local sParts = {}
      for seg in t.path:gmatch("[^/]+") do sParts[#sParts+1] = seg end
      if #sParts > 1 then
        local sDir = ""
        for i = 1, #sParts - 1 do
          sDir = sDir .. "/" .. sParts[i]
          if not vol:stat(sDir) then vol:mkdir(sDir) end
        end
      end
      vol:writeFile(t.path, sAll)
    end
    tHandles[h] = nil
    -- Periodic flush (delayed flush: don't flush on every write)
    nFlushCounter = nFlushCounter + 1
    if nFlushCounter >= FLUSH_INTERVAL then
      nFlushCounter = 0
      vol:flush()
    end
  end

  function proxy.list(sPath)
    sPath = (sPath or "/"):gsub("//", "/")
    if sPath == "" then sPath = "/" end
    local ents, err = vol:listDir(sPath)
    if not ents then return nil, err end
    local r = {}
    for _, e in ipairs(ents) do
      r[#r+1] = e.iType == 2 and (e.name.."/") or e.name
    end
    table.sort(r)
    return r
  end

  function proxy.isDirectory(sPath)
    local t = vol:stat(sPath)
    return t and t.iType == 2
  end

  function proxy.exists(sPath)
    return vol:resolve(sPath) ~= nil
  end

  function proxy.makeDirectory(sPath)
    return vol:mkdir(sPath)
  end

  function proxy.remove(sPath)
    local bOk = vol:removeFile(sPath)
    if not bOk then bOk = vol:rmdir(sPath) end
    return bOk
  end

  function proxy.size(sPath)
    local t = vol:stat(sPath)
    return t and t.size or 0
  end

  function proxy.lastModified(sPath)
    local t = vol:stat(sPath)
    return t and t.mtime or 0
  end

  function proxy.rename(sFrom, sTo)
    return vol:rename(sFrom, sTo)
  end

  function proxy.spaceUsed()
    local t = vol:info()
    return (t.maxBlocks - t.freeBlocks) * t.sectorSize
  end

  function proxy.spaceTotal()
    local t = vol:info()
    return t.maxBlocks * t.sectorSize
  end

  function proxy.getLabel() return proxy._label end
  function proxy.setLabel(s) proxy._label=s; return s end

  function proxy.flush() vol:flush() end

  -- Extended methods (not part of OC filesystem API)
  function proxy.health() return vol:health() end
  function proxy.cacheStats() return vol:cacheStats() end
  function proxy.volumeInfo() return vol:info() end
  function proxy.setCow(b) return vol:setCow(b) end

  return proxy
end

return P