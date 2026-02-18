--
-- /lib/registry.lua
-- AxisOS Virtual Registry — @VT Namespace
-- Hierarchical key-value store for device, driver, and system metadata.
--
-- Path format: @VT\DEV\VIRT_001  (backslash separated, @VT root)
-- Values are typed: STR, NUM, BOOL, TAB
--

local oReg = {}

-- =============================================
-- INTERNAL TREE
-- =============================================

local g_nNextDevId = 1
local g_nUptime = 0

local function fUptime()
    pcall(function()
        if raw_computer then
            g_nUptime = raw_computer.uptime()
        end
    end)
    return g_nUptime
end

local function fNewNode(sName)
    return {
        sName     = sName,
        tSubKeys  = {},
        tValues   = {},
        tMeta     = {
            nCreated  = fUptime(),
            nModified = fUptime(),
            nOwnerPid = 0,
        },
    }
end

local g_tRoot = fNewNode("@VT")

-- =============================================
-- PATH NAVIGATION
-- =============================================

local function fParsePath(sPath)
    if not sPath or #sPath == 0 then return {} end
    local sStripped = sPath
    -- strip @VT prefix
    if sStripped == "@VT" then return {} end
    if sStripped:sub(1, 4) == "@VT\\" then
        sStripped = sStripped:sub(5)
    elseif sStripped:sub(1, 3) == "@VT" then
        sStripped = sStripped:sub(4)
        if sStripped:sub(1, 1) == "\\" then sStripped = sStripped:sub(2) end
    end
    if #sStripped == 0 then return {} end
    local tParts = {}
    local nStart = 1
    for i = 1, #sStripped do
        if sStripped:sub(i, i) == "\\" then
            if i > nStart then
                table.insert(tParts, sStripped:sub(nStart, i - 1))
            end
            nStart = i + 1
        end
    end
    if nStart <= #sStripped then
        table.insert(tParts, sStripped:sub(nStart))
    end
    return tParts
end

local function fNavigate(sPath, bCreate)
    local tParts = fParsePath(sPath)
    local tCur = g_tRoot
    for _, sPart in ipairs(tParts) do
        if not tCur.tSubKeys[sPart] then
            if bCreate then
                tCur.tSubKeys[sPart] = fNewNode(sPart)
            else
                return nil
            end
        end
        tCur = tCur.tSubKeys[sPart]
    end
    return tCur
end

local function fGetParentAndChild(sPath)
    local tParts = fParsePath(sPath)
    if #tParts == 0 then return nil, nil end
    local sChild = table.remove(tParts)
    local sParent = "@VT"
    if #tParts > 0 then sParent = "@VT\\" .. table.concat(tParts, "\\") end
    return sParent, sChild
end

-- =============================================
-- PUBLIC API — KEY OPERATIONS
-- =============================================

function oReg.CreateKey(sPath)
    local tNode = fNavigate(sPath, true)
    return tNode ~= nil
end

function oReg.DeleteKey(sPath)
    local sParent, sChild = fGetParentAndChild(sPath)
    if not sParent or not sChild then return false end
    local tParent = fNavigate(sParent, false)
    if not tParent then return false end
    tParent.tSubKeys[sChild] = nil
    tParent.tMeta.nModified = fUptime()
    return true
end

function oReg.KeyExists(sPath)
    return fNavigate(sPath, false) ~= nil
end

-- =============================================
-- PUBLIC API — VALUE OPERATIONS
-- =============================================

function oReg.SetValue(sPath, sName, vValue, sType)
    local tNode = fNavigate(sPath, false)
    if not tNode then return false end
    if not sType then
        local t = type(vValue)
        if t == "number" then sType = "NUM"
        elseif t == "boolean" then sType = "BOOL"
        elseif t == "table" then sType = "TAB"
        else sType = "STR" end
    end
    tNode.tValues[sName] = { sType = sType, value = vValue }
    tNode.tMeta.nModified = fUptime()
    return true
end

function oReg.GetValue(sPath, sName)
    local tNode = fNavigate(sPath, false)
    if not tNode then return nil, nil end
    local tEntry = tNode.tValues[sName]
    if not tEntry then return nil, nil end
    return tEntry.value, tEntry.sType
end

function oReg.DeleteValue(sPath, sName)
    local tNode = fNavigate(sPath, false)
    if not tNode then return false end
    tNode.tValues[sName] = nil
    tNode.tMeta.nModified = fUptime()
    return true
end

-- =============================================
-- PUBLIC API — ENUMERATION
-- =============================================

function oReg.EnumKeys(sPath)
    local tNode = fNavigate(sPath, false)
    if not tNode then return {} end
    local tResult = {}
    for sName in pairs(tNode.tSubKeys) do
        table.insert(tResult, sName)
    end
    table.sort(tResult)
    return tResult
end

function oReg.EnumValues(sPath)
    local tNode = fNavigate(sPath, false)
    if not tNode then return {} end
    local tResult = {}
    for sName, tEntry in pairs(tNode.tValues) do
        table.insert(tResult, {
            sName = sName,
            sType = tEntry.sType,
            value = tEntry.value,
        })
    end
    table.sort(tResult, function(a, b) return a.sName < b.sName end)
    return tResult
end

function oReg.QueryInfo(sPath)
    local tNode = fNavigate(sPath, false)
    if not tNode then return nil end
    local nSubKeys = 0
    for _ in pairs(tNode.tSubKeys) do nSubKeys = nSubKeys + 1 end
    local nValues = 0
    for _ in pairs(tNode.tValues) do nValues = nValues + 1 end
    return {
        sName     = tNode.sName,
        nSubKeys  = nSubKeys,
        nValues   = nValues,
        nCreated  = tNode.tMeta.nCreated,
        nModified = tNode.tMeta.nModified,
        nOwnerPid = tNode.tMeta.nOwnerPid,
    }
end

-- =============================================
-- PUBLIC API — DEVICE ID GENERATION
-- =============================================

function oReg.AllocateDeviceId(sClass)
    local sPrefix = "DEV"
    if sClass == "virtual" then sPrefix = "VIRT"
    elseif sClass == "physical" then sPrefix = "PHYS"
    elseif sClass == "network" then sPrefix = "NET"
    elseif sClass == "block" then sPrefix = "BLK"
    end
    local sId = sPrefix .. "_" .. string.format("%03d", g_nNextDevId)
    g_nNextDevId = g_nNextDevId + 1
    return sId
end

-- =============================================
-- PUBLIC API — TREE DUMP (for debug/export)
-- =============================================

function oReg.DumpTree(sPath, nMaxDepth)
    nMaxDepth = nMaxDepth or 20
    local tResult = {}

    local function walk(sNodePath, nDepth)
        if nDepth > nMaxDepth then return end
        local tInfo = oReg.QueryInfo(sNodePath)
        if not tInfo then return end
        table.insert(tResult, {
            sPath    = sNodePath,
            nDepth   = nDepth,
            sName    = tInfo.sName,
            nSubKeys = tInfo.nSubKeys,
            nValues  = tInfo.nValues,
        })
        local tKeys = oReg.EnumKeys(sNodePath)
        for _, sKey in ipairs(tKeys) do
            walk(sNodePath .. "\\" .. sKey, nDepth + 1)
        end
    end

    walk(sPath or "@VT", 0)
    return tResult
end

-- =============================================
-- INITIALIZATION
-- =============================================

function oReg.InitSystem()
    fNavigate("@VT\\DEV", true)
    fNavigate("@VT\\DRV", true)
    fNavigate("@VT\\SYS", true)
    fNavigate("@VT\\SYS\\BOOT", true)
    fNavigate("@VT\\SYS\\CONFIG", true)
    fNavigate("@VT\\SYS\\HARDWARE", true)

    oReg.SetValue("@VT\\SYS\\BOOT", "KernelVersion", "0.3", "STR")
    oReg.SetValue("@VT\\SYS\\BOOT", "BootTime", fUptime(), "NUM")
    oReg.SetValue("@VT\\SYS\\BOOT", "RegistryVersion", "1.0.0", "STR")
end

return oReg