--
-- /lib/ob_manager.lua
-- AxisOS Object Manager — WDM Model
--
-- Implements the kernel object namespace, per-process handle tables,
-- reference-counted object headers, typed objects, access masks,
-- sMLTR-bound handles, standard I/O handle slots, and inheritable
-- handle duplication.
--
-- No file descriptors. No aliases. Handles are opaque tokens.
--

local oOb = {}

-- =============================================
-- CONSTANTS
-- =============================================

-- Object Types (IoCreateDevice, ObCreateObjectType, etc.)
oOb.OB_TYPE_DIRECTORY   = "ObpDirectory"
oOb.OB_TYPE_SYMLINK     = "ObpSymbolicLink"
oOb.OB_TYPE_DEVICE      = "IoDeviceObject"
oOb.OB_TYPE_FILE        = "IoFileObject"
oOb.OB_TYPE_DRIVER      = "IoDriverObject"
oOb.OB_TYPE_EVENT       = "KeEvent"
oOb.OB_TYPE_SECTION     = "MmSectionObject"

-- Access Mask Bits
oOb.ACCESS_READ            = 0x0001
oOb.ACCESS_WRITE           = 0x0002
oOb.ACCESS_EXECUTE         = 0x0004
oOb.ACCESS_DEVICE_CONTROL  = 0x0008
oOb.ACCESS_DELETE          = 0x0010
oOb.ACCESS_READ_ATTRIBUTES = 0x0020
oOb.ACCESS_SYNCHRONIZE     = 0x0040
oOb.ACCESS_ALL             = 0x007F

-- Generic Access (mapped at open time like GENERIC_READ/GENERIC_WRITE)
oOb.GENERIC_READ    = 0x0021  -- READ | READ_ATTRIBUTES
oOb.GENERIC_WRITE   = 0x0002
oOb.GENERIC_EXECUTE = 0x0004
oOb.GENERIC_ALL     = 0x007F

-- Well-Known Standard Handle Indices (GetStdHandle/SetStdHandle)
oOb.STD_INPUT_HANDLE  = -10
oOb.STD_OUTPUT_HANDLE = -11
oOb.STD_ERROR_HANDLE  = -12

-- Status Codes (NTSTATUS style)
oOb.STATUS_SUCCESS                = 0
oOb.STATUS_OBJECT_NAME_NOT_FOUND  = 0xC0000034
oOb.STATUS_OBJECT_NAME_COLLISION  = 0xC0000035
oOb.STATUS_OBJECT_TYPE_MISMATCH   = 0xC0000024
oOb.STATUS_INVALID_HANDLE         = 0xC0000008
oOb.STATUS_ACCESS_DENIED          = 0xC0000022
oOb.STATUS_OBJECT_NAME_INVALID    = 0xC0000033
oOb.STATUS_HANDLE_NOT_CLOSABLE    = 0xC0000235
oOb.STATUS_DELETE_PENDING         = 0xC0000056

-- =============================================
-- INTERNAL STATE
-- =============================================

local g_tObjectDirectory = {}       -- sKernelPath -> OBJECT_HEADER
local g_tProcessHandleTables = {}   -- nPid -> PROCESS_HANDLE_TABLE
local g_tObjectTypes = {}           -- sTypeName -> TYPE_OBJECT

local g_nHandleEntropy  = 0
local g_nObjectIdSeq    = 0

-- =============================================
-- BIT HELPERS (Lua 5.2 safe)
-- =============================================

local bit32 = bit32

local function fCheckAccess(nGranted, nRequired)
    if nRequired == 0 then return true end
    if bit32 then
        return bit32.band(nGranted, nRequired) == nRequired
    end
    local nBit = 1
    while nBit <= nRequired do
        local nReqBit  = math.floor(nRequired / nBit) % 2
        local nGranBit = math.floor(nGranted  / nBit) % 2
        if nReqBit == 1 and nGranBit == 0 then return false end
        nBit = nBit * 2
    end
    return true
end

-- =============================================
-- ENTROPY
-- =============================================

local function fUptime()
    local n = 0
    pcall(function()
        if raw_computer then n = math.floor(raw_computer.uptime() * 100000)
        else n = math.floor(os.clock() * 100000) end
    end)
    return n
end

local function fGenerateToken(sPrefix)
    g_nHandleEntropy = g_nHandleEntropy + 1
    local t = fUptime()
    return string.format("%s%06x-%05x-%04x-%04x",
        sPrefix or "H-",
        math.random(0, 0xFFFFFF),
        t % 0xFFFFF,
        math.random(0, 0xFFFF),
        (g_nHandleEntropy * 7 + math.random(0, 0xFF)) % 0xFFFF)
end

local function fNextObjectId()
    g_nObjectIdSeq = g_nObjectIdSeq + 1
    return g_nObjectIdSeq
end

-- =============================================
-- OBJECT TYPE REGISTRATION
-- (ObCreateObjectType)
-- =============================================

function oOb.ObCreateObjectType(sTypeName, tProcs)
    g_tObjectTypes[sTypeName] = {
        sTypeName        = sTypeName,
        fDeleteProcedure = tProcs.fDeleteProcedure,  -- ref→0: destroy body
        fCloseProcedure  = tProcs.fCloseProcedure,   -- per-handle close
        fOpenProcedure   = tProcs.fOpenProcedure,    -- post-lookup open
        fParseProcedure  = tProcs.fParseProcedure,   -- name parsing into sub-objects
        nTotalObjects    = 0,
        nTotalHandles    = 0,
    }
end

function oOb.ObGetObjectType(sTypeName)
    return g_tObjectTypes[sTypeName]
end

-- =============================================
-- OBJECT HEADER LIFECYCLE
-- (ObCreateObject, ObReferenceObject, ObDereferenceObject)
-- =============================================

function oOb.ObCreateObject(sType, tBody)
    local pType = g_tObjectTypes[sType]

    local pHeader = {
        nObjectId       = fNextObjectId(),
        sType           = sType,
        sName           = nil,            -- set by ObInsertObject
        nReferenceCount = 1,              -- creator holds initial ref
        nHandleCount    = 0,
        tSecurity       = {
            nOwnerUid = 0,
            nGroupGid = 0,
            nMode     = 755,
        },
        pBody           = tBody or {},
        bPermanent      = false,
        bDeletePending  = false,
        pTypeObject     = pType,
    }

    if pType then pType.nTotalObjects = pType.nTotalObjects + 1 end
    return pHeader
end

function oOb.ObReferenceObject(pH)
    if pH then pH.nReferenceCount = pH.nReferenceCount + 1 end
end

function oOb.ObDereferenceObject(pH)
    if not pH then return end
    pH.nReferenceCount = pH.nReferenceCount - 1
    if pH.nReferenceCount <= 0 and pH.nHandleCount <= 0 and not pH.bPermanent then
        if pH.pTypeObject and pH.pTypeObject.fDeleteProcedure then
            pcall(pH.pTypeObject.fDeleteProcedure, pH)
        end
        if pH.sName then g_tObjectDirectory[pH.sName] = nil end
        if pH.pTypeObject then
            pH.pTypeObject.nTotalObjects = pH.pTypeObject.nTotalObjects - 1
        end
    end
end

-- =============================================
-- KERNEL NAMESPACE (OBJECT DIRECTORY)
-- (ObInsertObject, ObLookupObject, ObDeleteObject)
-- =============================================

function oOb.ObInsertObject(pH, sPath)
    if not sPath or #sPath == 0 then return oOb.STATUS_OBJECT_NAME_INVALID end
    if g_tObjectDirectory[sPath]  then return oOb.STATUS_OBJECT_NAME_COLLISION end
    pH.sName = sPath
    g_tObjectDirectory[sPath] = pH
    return oOb.STATUS_SUCCESS
end

function oOb.ObLookupObject(sPath, nMaxDepth)
    nMaxDepth = nMaxDepth or 8
    local pH = g_tObjectDirectory[sPath]
    if not pH then return nil, oOb.STATUS_OBJECT_NAME_NOT_FOUND end
    -- transparently chase symlinks
    if pH.sType == oOb.OB_TYPE_SYMLINK and nMaxDepth > 0 then
        local sTarget = pH.pBody and pH.pBody.sTargetPath
        if sTarget then return oOb.ObLookupObject(sTarget, nMaxDepth - 1) end
    end
    return pH, oOb.STATUS_SUCCESS
end

function oOb.ObDeleteObject(sPath)
    local pH = g_tObjectDirectory[sPath]
    if not pH then return oOb.STATUS_OBJECT_NAME_NOT_FOUND end
    g_tObjectDirectory[sPath] = nil
    pH.sName = nil
    pH.bDeletePending = true
    oOb.ObDereferenceObject(pH)
    return oOb.STATUS_SUCCESS
end

-- =============================================
-- SYMBOLIC LINKS
-- (IoCreateSymbolicLink / IoDeleteSymbolicLink)
-- =============================================

function oOb.ObCreateSymbolicLink(sLinkPath, sTargetPath)
    local pH = oOb.ObCreateObject(oOb.OB_TYPE_SYMLINK, {
        sTargetPath = sTargetPath,
    })
    pH.bPermanent = true
    return oOb.ObInsertObject(pH, sLinkPath)
end

function oOb.ObDeleteSymbolicLink(sPath)
    return oOb.ObDeleteObject(sPath)
end

-- =============================================
-- DIRECTORY ENUMERATION
-- =============================================

function oOb.ObListDirectory(sPrefix)
    if sPrefix:sub(-1) ~= "\\" then sPrefix = sPrefix .. "\\" end
    local tOut = {}
    for sObjPath, pH in pairs(g_tObjectDirectory) do
        if #sObjPath > #sPrefix and sObjPath:sub(1, #sPrefix) == sPrefix then
            local sRem = sObjPath:sub(#sPrefix + 1)
            if not sRem:find("\\") then
                table.insert(tOut, {
                    sName     = sRem,
                    sFullPath = sObjPath,
                    sType     = pH.sType,
                })
            end
        end
    end
    return tOut
end

-- =============================================
-- PER-PROCESS HANDLE TABLE
-- =============================================

local function fNewHandleTable()
    return {
        tEntries         = {},   -- sToken -> HANDLE_ENTRY
        tStandardHandles = {},   -- nStdIndex -> sToken
    }
end

function oOb.ObInitializeProcess(nPid)
    if not g_tProcessHandleTables[nPid] then
        g_tProcessHandleTables[nPid] = fNewHandleTable()
    end
end

function oOb.ObDestroyProcess(nPid)
    local tHT = g_tProcessHandleTables[nPid]
    if not tHT then return end
    for sToken, tEntry in pairs(tHT.tEntries) do
        local pH = tEntry.pObjectHeader
        if pH then
            pH.nHandleCount = pH.nHandleCount - 1
            if pH.pTypeObject and pH.pTypeObject.fCloseProcedure then
                pcall(pH.pTypeObject.fCloseProcedure, pH, nPid, tEntry)
            end
            if pH.pTypeObject then
                pH.pTypeObject.nTotalHandles = pH.pTypeObject.nTotalHandles - 1
            end
            -- if nothing else references it, clean up
            if pH.nReferenceCount <= 0 and pH.nHandleCount <= 0 and not pH.bPermanent then
                if pH.pTypeObject and pH.pTypeObject.fDeleteProcedure then
                    pcall(pH.pTypeObject.fDeleteProcedure, pH)
                end
                if pH.sName then g_tObjectDirectory[pH.sName] = nil end
            end
        end
    end
    g_tProcessHandleTables[nPid] = nil
end

-- =============================================
-- HANDLE OPERATIONS
-- =============================================

--  ObCreateHandle(nPid, pObjectHeader, nDesiredAccess, sSynapseToken [, bInheritable])
--  → sHandleToken, nStatus
--
--  Access is checked HERE. Every subsequent use only validates token + sMLTR.
function oOb.ObCreateHandle(nPid, pH, nDesiredAccess, sSynapseToken, bInheritable)
    if not pH then return nil, oOb.STATUS_INVALID_HANDLE end
    oOb.ObInitializeProcess(nPid)
    local tHT = g_tProcessHandleTables[nPid]

    -- TODO: SeAccessCheck against pH.tSecurity.  For now, grant what was requested.
    local nGranted = nDesiredAccess or oOb.ACCESS_ALL

    local sToken = fGenerateToken("H-")
    while tHT.tEntries[sToken] do sToken = fGenerateToken("H-") end

    tHT.tEntries[sToken] = {
        pObjectHeader  = pH,
        nGrantedAccess = nGranted,
        sSynapseToken  = sSynapseToken,
        bInheritable   = (bInheritable ~= false),
        nCreationTime  = fUptime(),
    }

    pH.nHandleCount = pH.nHandleCount + 1
    if pH.pTypeObject then
        pH.pTypeObject.nTotalHandles = pH.pTypeObject.nTotalHandles + 1
    end

    return sToken, oOb.STATUS_SUCCESS
end

--  ObOpenObjectByName — lookup + ref + create handle
function oOb.ObOpenObjectByName(nPid, sPath, nDesiredAccess, sSynapseToken)
    local pH, nSt = oOb.ObLookupObject(sPath)
    if not pH then return nil, nSt end
    if pH.bDeletePending then return nil, oOb.STATUS_DELETE_PENDING end

    oOb.ObReferenceObject(pH)
    local sToken, nCreateSt = oOb.ObCreateHandle(nPid, pH, nDesiredAccess, sSynapseToken)
    if not sToken then
        oOb.ObDereferenceObject(pH)
        return nil, nCreateSt
    end
    return sToken, oOb.STATUS_SUCCESS
end

--  ObReferenceObjectByHandle — validate token, sMLTR, access → OBJECT_HEADER
--
--  vHandle may be:
--      string  → direct token lookup
--      number < 0  → standard-handle constant (STD_INPUT_HANDLE etc.)
--
--  Returns: pObjectHeader, nStatus, tHandleEntry
function oOb.ObReferenceObjectByHandle(nPid, vHandle, nDesiredAccess, sSynapseToken)
    local tHT = g_tProcessHandleTables[nPid]
    if not tHT then return nil, oOb.STATUS_INVALID_HANDLE end

    -- resolve standard-handle constants
    local sRealToken = vHandle
    if type(vHandle) == "number" and vHandle < 0 then
        sRealToken = tHT.tStandardHandles[vHandle]
        if not sRealToken then return nil, oOb.STATUS_INVALID_HANDLE end
    end

    local tEntry = tHT.tEntries[sRealToken]
    if not tEntry then return nil, oOb.STATUS_INVALID_HANDLE end

    -- sMLTR validation (skip for system PIDs < 20)
    if nPid >= 20 and tEntry.sSynapseToken and sSynapseToken then
        if tEntry.sSynapseToken ~= sSynapseToken then
            return nil, oOb.STATUS_ACCESS_DENIED
        end
    end

    -- access-mask check
    if nDesiredAccess and nDesiredAccess > 0 then
        if not fCheckAccess(tEntry.nGrantedAccess, nDesiredAccess) then
            return nil, oOb.STATUS_ACCESS_DENIED
        end
    end

    return tEntry.pObjectHeader, oOb.STATUS_SUCCESS, tEntry
end

--  ObCloseHandle — remove entry, dereference object
function oOb.ObCloseHandle(nPid, vHandle)
    local tHT = g_tProcessHandleTables[nPid]
    if not tHT then return false, oOb.STATUS_INVALID_HANDLE end

    local sRealToken = vHandle
    if type(vHandle) == "number" and vHandle < 0 then
        sRealToken = tHT.tStandardHandles[vHandle]
        if not sRealToken then return false, oOb.STATUS_INVALID_HANDLE end
        tHT.tStandardHandles[vHandle] = nil
    end

    local tEntry = tHT.tEntries[sRealToken]
    if not tEntry then return false, oOb.STATUS_INVALID_HANDLE end

    local pH = tEntry.pObjectHeader
    tHT.tEntries[sRealToken] = nil

    -- clean up any standard-handle slots pointing at this token
    for nK, sV in pairs(tHT.tStandardHandles) do
        if sV == sRealToken then tHT.tStandardHandles[nK] = nil end
    end

    if pH then
        pH.nHandleCount = pH.nHandleCount - 1
        if pH.pTypeObject and pH.pTypeObject.fCloseProcedure then
            pcall(pH.pTypeObject.fCloseProcedure, pH, nPid, tEntry)
        end
        if pH.pTypeObject then
            pH.pTypeObject.nTotalHandles = pH.pTypeObject.nTotalHandles - 1
        end
        oOb.ObDereferenceObject(pH)
    end

    return true, oOb.STATUS_SUCCESS
end

-- =============================================
-- STANDARD HANDLES  (SetStdHandle / GetStdHandle)
-- =============================================

function oOb.ObSetStandardHandle(nPid, nIndex, sToken)
    oOb.ObInitializeProcess(nPid)
    g_tProcessHandleTables[nPid].tStandardHandles[nIndex] = sToken
    return true
end

function oOb.ObGetStandardHandle(nPid, nIndex)
    local tHT = g_tProcessHandleTables[nPid]
    if not tHT then return nil end
    return tHT.tStandardHandles[nIndex]
end

-- =============================================
-- HANDLE INHERITANCE
-- (NtInheritHandles — called during process creation)
-- =============================================

function oOb.ObInheritHandles(nParentPid, nChildPid, sChildSynapseToken)
    local tParent = g_tProcessHandleTables[nParentPid]
    if not tParent then return end
    oOb.ObInitializeProcess(nChildPid)
    local tChild = g_tProcessHandleTables[nChildPid]

    local tTokenMap = {}  -- parent-token → child-token

    for sParentToken, tEntry in pairs(tParent.tEntries) do
        if tEntry.bInheritable and tEntry.pObjectHeader then
            local pH = tEntry.pObjectHeader
            oOb.ObReferenceObject(pH)

            local sChildToken = fGenerateToken("H-")
            while tChild.tEntries[sChildToken] do sChildToken = fGenerateToken("H-") end

            tChild.tEntries[sChildToken] = {
                pObjectHeader  = pH,
                nGrantedAccess = tEntry.nGrantedAccess,
                sSynapseToken  = sChildSynapseToken,   -- REBIND
                bInheritable   = tEntry.bInheritable,
                nCreationTime  = fUptime(),
            }
            pH.nHandleCount = pH.nHandleCount + 1

            tTokenMap[sParentToken] = sChildToken
        end
    end

    -- map standard-handle slots
    for nStdKey, sParentToken in pairs(tParent.tStandardHandles) do
        if tTokenMap[sParentToken] then
            tChild.tStandardHandles[nStdKey] = tTokenMap[sParentToken]
        end
    end
end

-- =============================================
-- DUPLICATE HANDLE  (DuplicateHandle)
-- =============================================

function oOb.ObDuplicateHandle(nSrcPid, sSrcToken, nDstPid, nDesiredAccess, sSynapseToken)
    local tSrc = g_tProcessHandleTables[nSrcPid]
    if not tSrc then return nil, oOb.STATUS_INVALID_HANDLE end
    local tEntry = tSrc.tEntries[sSrcToken]
    if not tEntry or not tEntry.pObjectHeader then
        return nil, oOb.STATUS_INVALID_HANDLE
    end

    local pH = tEntry.pObjectHeader
    oOb.ObReferenceObject(pH)

    local nAcc = nDesiredAccess or tEntry.nGrantedAccess
    local sNew, nSt = oOb.ObCreateHandle(nDstPid, pH, nAcc, sSynapseToken)
    if not sNew then oOb.ObDereferenceObject(pH); return nil, nSt end
    return sNew, oOb.STATUS_SUCCESS
end

-- =============================================
-- QUERY / DEBUG  (!handle, !object, dt)
-- =============================================

function oOb.ObQueryObjectType(pH)  return pH and pH.sType end
function oOb.ObQueryObjectName(pH)  return pH and pH.sName end

function oOb.ObQueryObjectSecurity(pH)
    return pH and pH.tSecurity
end

function oOb.ObSetObjectSecurity(pH, tNew)
    if not pH then return false end
    for k, v in pairs(tNew) do pH.tSecurity[k] = v end
    return true
end

function oOb.ObListHandles(nPid)
    local tHT = g_tProcessHandleTables[nPid]
    if not tHT then return {} end
    local t = {}
    for sToken, tE in pairs(tHT.tEntries) do
        local pH = tE.pObjectHeader
        table.insert(t, {
            sToken         = sToken,
            sType          = pH and pH.sType or "INVALID",
            sName          = pH and pH.sName or "(unnamed)",
            nGrantedAccess = tE.nGrantedAccess,
            nRefCount      = pH and pH.nReferenceCount or 0,
            nHandleCount   = pH and pH.nHandleCount or 0,
            bInheritable   = tE.bInheritable,
        })
    end
    return t
end

function oOb.ObQueryTypeStatistics(sTypeName)
    local p = g_tObjectTypes[sTypeName]
    if not p then return nil end
    return { sTypeName = p.sTypeName, nTotalObjects = p.nTotalObjects, nTotalHandles = p.nTotalHandles }
end

function oOb.ObDumpDirectory()
    local t = {}
    for sPath, pH in pairs(g_tObjectDirectory) do
        table.insert(t, {
            sPath        = sPath,
            sType        = pH.sType,
            nRefCount    = pH.nReferenceCount,
            nHandleCount = pH.nHandleCount,
        })
    end
    table.sort(t, function(a, b) return a.sPath < b.sPath end)
    return t
end

-- =============================================
-- BOOT-TIME INITIALIZATION
-- =============================================

function oOb.ObInitSystem()
    -- register built-in types (procedures are no-ops; PM registers real ones later)
    local tEmpty = {}
    oOb.ObCreateObjectType(oOb.OB_TYPE_DIRECTORY, tEmpty)
    oOb.ObCreateObjectType(oOb.OB_TYPE_SYMLINK,   tEmpty)
    oOb.ObCreateObjectType(oOb.OB_TYPE_DEVICE,    tEmpty)
    oOb.ObCreateObjectType(oOb.OB_TYPE_FILE,      tEmpty)
    oOb.ObCreateObjectType(oOb.OB_TYPE_DRIVER,    tEmpty)
    oOb.ObCreateObjectType(oOb.OB_TYPE_EVENT,     tEmpty)
    oOb.ObCreateObjectType(oOb.OB_TYPE_SECTION,   tEmpty)

    -- create root namespace directories
    local function mkDir(sPath)
        local p = oOb.ObCreateObject(oOb.OB_TYPE_DIRECTORY, {})
        p.bPermanent = true
        oOb.ObInsertObject(p, sPath)
    end
    mkDir("\\")
    mkDir("\\Device")
    mkDir("\\DosDevices")
    mkDir("\\ObjectTypes")
end

return oOb