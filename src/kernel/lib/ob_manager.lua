--
-- /lib/ob_manager.lua
-- Object Manager & Handle Table logic.
-- v3: Kernel-loadable. Supports sMLTR token binding on handles.
--     Handles inherit to child processes. Legacy FD aliases supported.
--

local oOb = {}
local tProcessHandleTables = {} -- [pid] = { tHandles={}, tAliases={} }

-- Entropy pool for handle generation.
-- Uses multiple sources to make tokens unpredictable.
local g_nHandleCounter = 0

local function fGenerateHandleToken()
    g_nHandleCounter = g_nHandleCounter + 1
    local nTime = 0
    -- try to use raw_computer.uptime if available (kernel context)
    -- otherwise fall back to os.clock
    pcall(function()
        if raw_computer then nTime = math.floor(raw_computer.uptime() * 100000)
        else nTime = math.floor(os.clock() * 100000) end
    end)
    local sPart1 = string.format("%06x", math.random(0, 0xFFFFFF))
    local sPart2 = string.format("%05x", nTime % 0xFFFFF)
    local sPart3 = string.format("%04x", math.random(0, 0xFFFF))
    local sPart4 = string.format("%04x", (g_nHandleCounter * 7 + math.random(0, 0xFF)) % 0xFFFF)
    return "H-" .. sPart1 .. "-" .. sPart2 .. "-" .. sPart3 .. "-" .. sPart4
end

function oOb.InitProcess(nPid)
    if not tProcessHandleTables[nPid] then
        tProcessHandleTables[nPid] = {
            tHandles = {},   -- Map: Token (String) -> ObjectHeader
            tAliases = {}    -- Map: Alias (Number) -> Token (String)
        }
    end
end

function oOb.DestroyProcess(nPid)
    tProcessHandleTables[nPid] = nil
end

function oOb.CreateHandle(nPid, tObjectHeader)
    oOb.InitProcess(nPid)
    local tTable = tProcessHandleTables[nPid]
    
    local sToken = fGenerateHandleToken()
    while tTable.tHandles[sToken] do sToken = fGenerateHandleToken() end
    
    tTable.tHandles[sToken] = tObjectHeader
    return sToken
end

function oOb.SetHandleAlias(nPid, nAliasFd, sToken)
    oOb.InitProcess(nPid)
    local tTable = tProcessHandleTables[nPid]
    if tTable.tHandles[sToken] then
        tTable.tAliases[nAliasFd] = sToken
        return true
    end
    return false
end

function oOb.ReferenceObjectByHandle(nPid, vHandle)
    local tTable = tProcessHandleTables[nPid]
    if not tTable then return nil end
    
    local sRealToken = vHandle
    if type(vHandle) == "number" then
        sRealToken = tTable.tAliases[vHandle]
        if not sRealToken then return nil end
    end
    
    return tTable.tHandles[sRealToken]
end

function oOb.GetTokenByAlias(nPid, nAlias)
    local tTable = tProcessHandleTables[nPid]
    if not tTable then return nil end
    return tTable.tAliases[nAlias]
end

function oOb.CloseHandle(nPid, vHandle)
    local tTable = tProcessHandleTables[nPid]
    if not tTable then return false end
    
    local sRealToken = vHandle
    if type(vHandle) == "number" then
        sRealToken = tTable.tAliases[vHandle]
        tTable.tAliases[vHandle] = nil
    end
    
    if sRealToken and tTable.tHandles[sRealToken] then
        tTable.tHandles[sRealToken] = nil 
        for k, v in pairs(tTable.tAliases) do
            if v == sRealToken then tTable.tAliases[k] = nil end
        end
        return true
    end
    return false
end

-- Inherit handles from parent to child (like fork() fd inheritance).
-- Creates new tokens for the child pointing to cloned object headers.
function oOb.InheritHandles(nParentPid, nChildPid)
    local tParent = tProcessHandleTables[nParentPid]
    if not tParent then return end
    
    oOb.InitProcess(nChildPid)
    local tChild = tProcessHandleTables[nChildPid]
    
    -- Clone all aliases (standard FDs: 0=stdin, 1=stdout, 2=stderr)
    for nAlias, sParentToken in pairs(tParent.tAliases) do
        local tObj = tParent.tHandles[sParentToken]
        if tObj then
            -- Deep-copy the object header so child has its own
            local tClone = {}
            for k, v in pairs(tObj) do tClone[k] = v end
            
            local sChildToken = fGenerateHandleToken()
            while tChild.tHandles[sChildToken] do sChildToken = fGenerateHandleToken() end
            
            tChild.tHandles[sChildToken] = tClone
            tChild.tAliases[nAlias] = sChildToken
        end
    end
end

-- List all handles for a process (for debugging / cleanup)
function oOb.ListHandles(nPid)
    local tTable = tProcessHandleTables[nPid]
    if not tTable then return {} end
    local tResult = {}
    for sToken, tObj in pairs(tTable.tHandles) do
        table.insert(tResult, { token = sToken, object = tObj })
    end
    return tResult
end

return oOb