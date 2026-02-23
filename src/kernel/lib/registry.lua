--
-- /lib/registry.lua
-- AxisOS Virtual Registry — @VT Namespace
-- v2: Persistent hive files on disk, lazy writeback, transaction logging.
--
-- Hive files stored in /etc/registry/:
--   SYS.hive   — @VT\SYS  (system config, boot params)
--   DEV.hive   — @VT\DEV  (device metadata)
--   DRV.hive   — @VT\DRV  (driver configuration)
--   USER.hive  — @VT\USER (user preferences)
--
-- Changes are written lazily: only on explicit flush or shutdown.
-- A dirty flag per hive tracks whether disk write is needed.
--

local oReg = {}

local g_nNextDevId = 1
local g_nUptime = 0
local g_fRawFs = nil       -- raw filesystem proxy (set by InitSystem)
local g_bPersistence = false

local HIVE_DIR = "/etc/registry"
local HIVE_MAP = {
    SYS  = "SYS.hive",
    DEV  = "DEV.hive",
    DRV  = "DRV.hive",
    USER = "USER.hive",
}

local g_tHiveDirty = {}  -- [hiveName] = true if needs flushing

local function fUptime()
    pcall(function()
        if raw_computer then g_nUptime = raw_computer.uptime() end
    end)
    return g_nUptime
end

local function fNewNode(sName)
    return {
        sName = sName,
        tSubKeys = {},
        tValues = {},
        tMeta = { nCreated = fUptime(), nModified = fUptime(), nOwnerPid = 0 },
    }
end

local g_tRoot = fNewNode("@VT")

-- =============================================
-- PATH NAVIGATION (unchanged)
-- =============================================

local function fParsePath(sPath)
    if not sPath or #sPath == 0 then return {} end
    local sStripped = sPath
    if sStripped == "@VT" then return {} end
    if sStripped:sub(1, 4) == "@VT\\" then sStripped = sStripped:sub(5)
    elseif sStripped:sub(1, 3) == "@VT" then
        sStripped = sStripped:sub(4)
        if sStripped:sub(1, 1) == "\\" then sStripped = sStripped:sub(2) end
    end
    if #sStripped == 0 then return {} end
    local tParts = {}
    local nStart = 1
    for i = 1, #sStripped do
        if sStripped:sub(i, i) == "\\" then
            if i > nStart then table.insert(tParts, sStripped:sub(nStart, i - 1)) end
            nStart = i + 1
        end
    end
    if nStart <= #sStripped then table.insert(tParts, sStripped:sub(nStart)) end
    return tParts
end

local function fNavigate(sPath, bCreate)
    local tParts = fParsePath(sPath)
    local tCur = g_tRoot
    for _, sPart in ipairs(tParts) do
        if not tCur.tSubKeys[sPart] then
            if bCreate then tCur.tSubKeys[sPart] = fNewNode(sPart)
            else return nil end
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
-- DIRTY TRACKING
-- =============================================

local function fMarkDirty(sPath)
    local tParts = fParsePath(sPath)
    if #tParts > 0 then
        local sHive = tParts[1]
        if HIVE_MAP[sHive] then
            g_tHiveDirty[sHive] = true
        end
    end
end

-- =============================================
-- PERSISTENCE: SERIALIZE / DESERIALIZE
-- =============================================

local function fSerializeNode(tNode, nDepth)
    nDepth = nDepth or 0
    if nDepth > 32 then return "nil" end
    local tL = {}
    local sI = string.rep("  ", nDepth)

    tL[#tL+1] = "{"
    -- Values
    for sName, tEntry in pairs(tNode.tValues) do
        local sVal
        if tEntry.sType == "STR" then
            sVal = string.format("%q", tostring(tEntry.value))
        elseif tEntry.sType == "NUM" then
            sVal = tostring(tEntry.value)
        elseif tEntry.sType == "BOOL" then
            sVal = tostring(tEntry.value)
        else
            sVal = string.format("%q", tostring(tEntry.value))
        end
        tL[#tL+1] = string.format('%s  _v={[%q]={t=%q,v=%s}},',
            sI, sName, tEntry.sType, sVal)
    end
    -- SubKeys (recursive)
    for sName, tSub in pairs(tNode.tSubKeys) do
        tL[#tL+1] = string.format('%s  [%q]=%s,',
            sI, sName, fSerializeNode(tSub, nDepth + 1))
    end
    tL[#tL+1] = sI .. "}"
    return table.concat(tL, "\n")
end

local function fSerializeHive(sHiveName)
    local tHive = g_tRoot.tSubKeys[sHiveName]
    if not tHive then return nil end

    local tL = {"-- AxisOS Registry Hive: " .. sHiveName}
    tL[#tL+1] = "-- Auto-generated. Do not edit while OS is running."
    tL[#tL+1] = "return {"

    -- Flatten: walk tree and emit path=value pairs
    local function walk(tNode, sPrefix)
        for sName, tEntry in pairs(tNode.tValues) do
            local sVal
            if tEntry.sType == "STR" then
                sVal = string.format("{t=%q,v=%q}", tEntry.sType, tostring(tEntry.value))
            elseif tEntry.sType == "NUM" then
                sVal = string.format("{t=%q,v=%s}", tEntry.sType, tostring(tEntry.value))
            elseif tEntry.sType == "BOOL" then
                sVal = string.format("{t=%q,v=%s}", tEntry.sType, tostring(tEntry.value))
            else
                sVal = string.format("{t=%q,v=%q}", "STR", tostring(tEntry.value))
            end
            tL[#tL+1] = string.format('  [%q]=%s,', sPrefix .. "\\" .. sName, sVal)
        end
        for sSubName, tSub in pairs(tNode.tSubKeys) do
            tL[#tL+1] = string.format('  [%q]="KEY",', sPrefix .. "\\" .. sSubName)
            walk(tSub, sPrefix .. "\\" .. sSubName)
        end
    end

    walk(tHive, sHiveName)
    tL[#tL+1] = "}"
    return table.concat(tL, "\n") .. "\n"
end

local function fLoadHive(sHiveName)
    if not g_fRawFs then return false end
    local sPath = HIVE_DIR .. "/" .. HIVE_MAP[sHiveName]

    local hFile = g_fRawFs.open(sPath, "r")
    if not hFile then return false end
    local tC = {}
    while true do
        local s = g_fRawFs.read(hFile, math.huge)
        if not s then break end
        tC[#tC+1] = s
    end
    g_fRawFs.close(hFile)
    local sData = table.concat(tC)
    if #sData == 0 then return false end

    local f = load(sData, "hive:" .. sHiveName, "t", {})
    if not f then return false end
    local bOk, tFlat = pcall(f)
    if not bOk or type(tFlat) ~= "table" then return false end

    -- Rebuild tree from flat representation
    -- First pass: create all keys
    for sKey, vVal in pairs(tFlat) do
        if vVal == "KEY" then
            oReg.CreateKey("@VT\\" .. sKey)
        end
    end
    -- Second pass: set all values
    for sKey, tEntry in pairs(tFlat) do
        if type(tEntry) == "table" and tEntry.t then
            local sLastSep = sKey:match(".*()\\")
            if sLastSep then
                local sParent = "@VT\\" .. sKey:sub(1, sLastSep - 1)
                local sValName = sKey:sub(sLastSep + 1)
                oReg.SetValue(sParent, sValName, tEntry.v, tEntry.t)
            end
        end
    end

    return true
end

local function fSaveHive(sHiveName)
    if not g_fRawFs then return false end
    local sData = fSerializeHive(sHiveName)
    if not sData then return false end

    pcall(function() g_fRawFs.makeDirectory(HIVE_DIR) end)

    local sPath = HIVE_DIR .. "/" .. HIVE_MAP[sHiveName]
    local hFile = g_fRawFs.open(sPath, "w")
    if not hFile then return false end
    g_fRawFs.write(hFile, sData)
    g_fRawFs.close(hFile)
    return true
end

-- =============================================
-- PUBLIC API — KEY OPERATIONS
-- =============================================

function oReg.CreateKey(sPath)
    local tNode = fNavigate(sPath, true)
    if tNode then fMarkDirty(sPath) end
    return tNode ~= nil
end

function oReg.DeleteKey(sPath)
    local sParent, sChild = fGetParentAndChild(sPath)
    if not sParent or not sChild then return false end
    local tParent = fNavigate(sParent, false)
    if not tParent then return false end
    tParent.tSubKeys[sChild] = nil
    tParent.tMeta.nModified = fUptime()
    fMarkDirty(sPath)
    return true
end

function oReg.KeyExists(sPath) return fNavigate(sPath, false) ~= nil end

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
    fMarkDirty(sPath)
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
    fMarkDirty(sPath)
    return true
end

-- =============================================
-- PUBLIC API — ENUMERATION (unchanged)
-- =============================================

function oReg.EnumKeys(sPath)
    local tNode = fNavigate(sPath, false)
    if not tNode then return {} end
    local tResult = {}
    for sName in pairs(tNode.tSubKeys) do table.insert(tResult, sName) end
    table.sort(tResult)
    return tResult
end

function oReg.EnumValues(sPath)
    local tNode = fNavigate(sPath, false)
    if not tNode then return {} end
    local tResult = {}
    for sName, tEntry in pairs(tNode.tValues) do
        table.insert(tResult, { sName = sName, sType = tEntry.sType, value = tEntry.value })
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
        sName = tNode.sName, nSubKeys = nSubKeys, nValues = nValues,
        nCreated = tNode.tMeta.nCreated, nModified = tNode.tMeta.nModified,
        nOwnerPid = tNode.tMeta.nOwnerPid,
    }
end

function oReg.AllocateDeviceId(sClass)
    local sPrefix = "DEV"
    if sClass == "virtual" then sPrefix = "VIRT"
    elseif sClass == "physical" then sPrefix = "PHYS"
    elseif sClass == "network" then sPrefix = "NET"
    elseif sClass == "block" then sPrefix = "BLK" end
    local sId = sPrefix .. "_" .. string.format("%03d", g_nNextDevId)
    g_nNextDevId = g_nNextDevId + 1
    return sId
end

function oReg.DumpTree(sPath, nMaxDepth)
    nMaxDepth = nMaxDepth or 20
    local tResult = {}
    local function walk(sNodePath, nDepth)
        if nDepth > nMaxDepth then return end
        local tInfo = oReg.QueryInfo(sNodePath)
        if not tInfo then return end
        table.insert(tResult, {
            sPath = sNodePath, nDepth = nDepth, sName = tInfo.sName,
            nSubKeys = tInfo.nSubKeys, nValues = tInfo.nValues,
        })
        for _, sKey in ipairs(oReg.EnumKeys(sNodePath)) do
            walk(sNodePath .. "\\" .. sKey, nDepth + 1)
        end
    end
    walk(sPath or "@VT", 0)
    return tResult
end

-- =============================================
-- PERSISTENCE API
-- =============================================

-- Flush all dirty hives to disk
function oReg.FlushAll()
    if not g_bPersistence then return 0 end
    local nFlushed = 0
    for sHive, bDirty in pairs(g_tHiveDirty) do
        if bDirty then
            if fSaveHive(sHive) then
                g_tHiveDirty[sHive] = false
                nFlushed = nFlushed + 1
            end
        end
    end
    return nFlushed
end

-- Flush a specific hive
function oReg.FlushHive(sHiveName)
    if not g_bPersistence or not HIVE_MAP[sHiveName] then return false end
    local bOk = fSaveHive(sHiveName)
    if bOk then g_tHiveDirty[sHiveName] = false end
    return bOk
end

-- Check if any hive is dirty
function oReg.IsDirty()
    for _, bDirty in pairs(g_tHiveDirty) do
        if bDirty then return true end
    end
    return false
end

-- =============================================
-- INITIALIZATION
-- =============================================

function oReg.InitSystem(oRawFs)
    -- Set up raw filesystem for persistence
    if oRawFs then
        g_fRawFs = oRawFs
        g_bPersistence = true
        pcall(function() oRawFs.makeDirectory(HIVE_DIR) end)
    end

    -- Create root hive structure
    fNavigate("@VT\\DEV", true)
    fNavigate("@VT\\DRV", true)
    fNavigate("@VT\\SYS", true)
    fNavigate("@VT\\SYS\\BOOT", true)
    fNavigate("@VT\\SYS\\CONFIG", true)
    fNavigate("@VT\\SYS\\HARDWARE", true)
    fNavigate("@VT\\USER", true)

    -- Load persisted hives from disk (overlays default structure)
    if g_bPersistence then
        local nLoaded = 0
        for sHive, _ in pairs(HIVE_MAP) do
            if fLoadHive(sHive) then nLoaded = nLoaded + 1 end
        end
        -- Clear dirty flags after load
        g_tHiveDirty = {}
    end

    -- Set boot-time values (always fresh)
    oReg.SetValue("@VT\\SYS\\BOOT", "KernelVersion", "0.3", "STR")
    oReg.SetValue("@VT\\SYS\\BOOT", "BootTime", fUptime(), "NUM")
    oReg.SetValue("@VT\\SYS\\BOOT", "RegistryVersion", "2.0.0", "STR")
    oReg.SetValue("@VT\\SYS\\BOOT", "PersistenceEnabled",
        g_bPersistence and "true" or "false", "STR")
end

return oReg