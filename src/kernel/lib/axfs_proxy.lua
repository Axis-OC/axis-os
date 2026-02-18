--
-- /lib/axfs_proxy.lua
-- Makes an AXFS volume look like an OC managed filesystem component.
-- PM, kernel primitive_load, and all file operations work transparently.
--

local AX = require("axfs_core")
local B  = require("bpack")

local P = {}

function P.createProxy(vol, sLabel)
  local tHandles = {}
  local nNextH = 1

  local proxy = {
    address = "axfs-" .. (sLabel or vol.su.label or "root"),
    type = "filesystem",
    _vol = vol,
    _label = sLabel or vol.su.label or "AXFS",
  }

  -- =============================================
  -- open(path, mode) → handle
  -- =============================================
  function proxy.open(sPath, sMode)
    sMode = sMode or "r"
    local sClean = sPath:gsub("//", "/")
    if sClean == "" then sClean = "/" end

    if sMode == "r" then
      local data, err = vol:readFile(sClean)
      if not data then return nil, err end
      local h = nNextH; nNextH = nNextH + 1
      tHandles[h] = {
        path = sClean, mode = "r",
        data = data, pos = 1,
      }
      return h

    elseif sMode == "w" then
      local h = nNextH; nNextH = nNextH + 1
      tHandles[h] = {
        path = sClean, mode = "w",
        chunks = {}, pos = 1,
      }
      return h

    elseif sMode == "a" then
      -- Read existing content first
      local existing = vol:readFile(sClean) or ""
      local h = nNextH; nNextH = nNextH + 1
      tHandles[h] = {
        path = sClean, mode = "w",
        chunks = {existing}, pos = #existing + 1,
      }
      return h

    else
      return nil, "Unsupported mode: " .. tostring(sMode)
    end
  end

  -- =============================================
  -- read(handle, count) → data or nil
  -- =============================================
  function proxy.read(h, nCount)
    local t = tHandles[h]
    if not t then return nil, "Bad handle" end
    if t.mode ~= "r" then return nil, "Not readable" end
    nCount = nCount or math.huge
    if t.pos > #t.data then return nil end
    local nEnd = math.min(t.pos + nCount - 1, #t.data)
    local s = t.data:sub(t.pos, nEnd)
    t.pos = nEnd + 1
    if #s == 0 then return nil end
    return s
  end

  -- =============================================
  -- write(handle, data) → true
  -- =============================================
  function proxy.write(h, sData)
    local t = tHandles[h]
    if not t then return nil, "Bad handle" end
    if t.mode ~= "w" then return nil, "Not writable" end
    t.chunks[#t.chunks + 1] = tostring(sData)
    return true
  end

  -- =============================================
  -- close(handle)
  -- =============================================
  function proxy.close(h)
    local t = tHandles[h]
    if not t then return end
    if t.mode == "w" and #t.chunks > 0 then
      local sAll = table.concat(t.chunks)
      -- Ensure parent directories exist
      local sParts = {}
      for seg in t.path:gmatch("[^/]+") do sParts[#sParts+1] = seg end
      if #sParts > 1 then
        local sDir = ""
        for i = 1, #sParts - 1 do
          sDir = sDir .. "/" .. sParts[i]
          local st = vol:stat(sDir)
          if not st then vol:mkdir(sDir) end
        end
      end
      vol:writeFile(t.path, sAll)
    end
    tHandles[h] = nil
  end

  -- =============================================
  -- list(path) → table of names
  -- =============================================
  function proxy.list(sPath)
    sPath = sPath or "/"
    sPath = sPath:gsub("//", "/")
    if sPath == "" then sPath = "/" end
    local ents, err = vol:listDir(sPath)
    if not ents then return nil, err end
    local r = {}
    for _, e in ipairs(ents) do
      if e.iType == 2 then -- DIR
        r[#r + 1] = e.name .. "/"
      else
        r[#r + 1] = e.name
      end
    end
    table.sort(r)
    return r
  end

  -- =============================================
  -- isDirectory(path)
  -- =============================================
  function proxy.isDirectory(sPath)
    local t = vol:stat(sPath)
    return t and t.iType == 2
  end

  -- =============================================
  -- exists(path)
  -- =============================================
  function proxy.exists(sPath)
    local n = vol:resolve(sPath)
    return n ~= nil
  end

  -- =============================================
  -- makeDirectory(path)
  -- =============================================
  function proxy.makeDirectory(sPath)
    return vol:mkdir(sPath)
  end

  -- =============================================
  -- remove(path)
  -- =============================================
  function proxy.remove(sPath)
    local bOk = vol:removeFile(sPath)
    if not bOk then bOk = vol:rmdir(sPath) end
    return bOk
  end

  -- =============================================
  -- size(path)
  -- =============================================
  function proxy.size(sPath)
    local t = vol:stat(sPath)
    return t and t.size or 0
  end

  -- =============================================
  -- lastModified(path)
  -- =============================================
  function proxy.lastModified(sPath)
    local t = vol:stat(sPath)
    return t and t.mtime or 0
  end

  -- =============================================
  -- rename(from, to)
  -- =============================================
  function proxy.rename(sFrom, sTo)
    return vol:rename(sFrom, sTo)
  end

  -- =============================================
  -- spaceUsed / spaceTotal
  -- =============================================
  function proxy.spaceUsed()
    local t = vol:info()
    return (t.maxBlocks - t.freeBlocks) * t.sectorSize
  end

  function proxy.spaceTotal()
    local t = vol:info()
    return t.maxBlocks * t.sectorSize
  end

  -- =============================================
  -- getLabel / setLabel
  -- =============================================
  function proxy.getLabel()
    return proxy._label
  end

  function proxy.setLabel(s)
    proxy._label = s
    return s
  end

  -- Flush on demand
  function proxy.flush()
    vol:flush()
  end

  return proxy
end

return P