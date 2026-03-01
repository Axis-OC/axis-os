--
-- /lib/net/nftables.lua
-- AxisOS nftables — Kernel Packet Filtering Pipeline
--
-- Full netfilter-style packet processing with:
--   • 5-hook chain model (prerouting, input, forward, output, postrouting)
--   • Connection tracking (conntrack) with state machine
--   • NAT (SNAT, DNAT, masquerade) with port mapping
--   • nfqueue: pass packets to userspace for DPI/modification
--   • Rule matching on IP/port/proto/flags/conntrack state
--   • Rate limiting (token bucket)
--   • Packet marking for policy routing
--

local NFT = {}

-- =============================================
-- CONSTANTS
-- =============================================

-- Hook points (Netfilter order)
NFT.HOOK_PREROUTING  = 1
NFT.HOOK_INPUT       = 2
NFT.HOOK_FORWARD     = 3
NFT.HOOK_OUTPUT      = 4
NFT.HOOK_POSTROUTING = 5

NFT.HOOK_NAMES = {
    [1] = "PREROUTING", [2] = "INPUT", [3] = "FORWARD",
    [4] = "OUTPUT", [5] = "POSTROUTING",
}

-- Verdicts (rule actions)
NFT.NF_DROP    = 0
NFT.NF_ACCEPT  = 1
NFT.NF_STOLEN  = 2   -- nfqueue took ownership
NFT.NF_QUEUE   = 3   -- pass to nfqueue
NFT.NF_REPEAT  = 4   -- re-evaluate from start
NFT.NF_STOP    = 5   -- stop processing this chain

-- Table types
NFT.TABLE_FILTER = "filter"
NFT.TABLE_NAT    = "nat"
NFT.TABLE_MANGLE = "mangle"

-- Connection tracking states
NFT.CT_NEW         = "new"
NFT.CT_ESTABLISHED = "established"
NFT.CT_RELATED     = "related"
NFT.CT_INVALID     = "invalid"

-- NAT types
NFT.NAT_SNAT       = "snat"
NFT.NAT_DNAT       = "dnat"
NFT.NAT_MASQUERADE = "masquerade"

-- =============================================
-- PROTOCOL IMPORTS
-- =============================================

local band = bit32.band
local bor  = bit32.bor

-- =============================================
-- CONNECTION TRACKING TABLE
-- =============================================

local g_tConntrack = {}   -- [5-tuple-key] → state
local g_nConntrackTimeout = 300   -- 5 min idle timeout
local g_nConntrackMax     = 1024

local function fConntrackKey(nProto, sSrcIP, nSrcPort, sDstIP, nDstPort)
    return string.format("%d:%s:%d:%s:%d",
        nProto,
        sSrcIP, nSrcPort or 0,
        sDstIP, nDstPort or 0)
end

local function fConntrackLookup(nProto, sSrcIP, nSrcPort, sDstIP, nDstPort)
    local sKey = fConntrackKey(nProto, sSrcIP, nSrcPort, sDstIP, nDstPort)
    local tEntry = g_tConntrack[sKey]
    if tEntry then
        if os.clock() > tEntry.nExpiry then
            g_tConntrack[sKey] = nil
            return nil
        end
        tEntry.nExpiry = os.clock() + g_nConntrackTimeout
        return tEntry
    end
    -- Check reverse direction (for established connections)
    local sRevKey = fConntrackKey(nProto, sDstIP, nDstPort, sSrcIP, nSrcPort)
    local tRev = g_tConntrack[sRevKey]
    if tRev then
        if os.clock() > tRev.nExpiry then
            g_tConntrack[sRevKey] = nil
            return nil
        end
        tRev.nExpiry = os.clock() + g_nConntrackTimeout
        return tRev
    end
    return nil
end

local function fConntrackInsert(nProto, sSrcIP, nSrcPort, sDstIP, nDstPort, sState)
    local sKey = fConntrackKey(nProto, sSrcIP, nSrcPort, sDstIP, nDstPort)
    g_tConntrack[sKey] = {
        sState   = sState,
        nExpiry  = os.clock() + g_nConntrackTimeout,
        nProto   = nProto,
        sSrcIP   = sSrcIP,
        nSrcPort = nSrcPort,
        sDstIP   = sDstIP,
        nDstPort = nDstPort,
        nPackets = 1,
        nBytes   = 0,
        tNAT     = nil,   -- NAT mapping if any
    }
    return g_tConntrack[sKey]
end

local function fConntrackUpdate(tEntry, sNewState, nBytes)
    tEntry.sState = sNewState
    tEntry.nPackets = tEntry.nPackets + 1
    tEntry.nBytes = tEntry.nBytes + (nBytes or 0)
    tEntry.nExpiry = os.clock() + g_nConntrackTimeout
end

local function fConntrackGC()
    local nNow = os.clock()
    local nRemoved = 0
    for k, e in pairs(g_tConntrack) do
        if nNow > e.nExpiry then
            g_tConntrack[k] = nil
            nRemoved = nRemoved + 1
        end
    end
    return nRemoved
end

--- Determine conntrack state for a packet
local function fGetConntrackState(tPkt)
    local nProto   = tPkt.nProto or 0
    local sSrcIP   = tPkt.sSrcIP or ""
    local sDstIP   = tPkt.sDstIP or ""
    local nSrcPort = tPkt.nSrcPort or 0
    local nDstPort = tPkt.nDstPort or 0

    local tExisting = fConntrackLookup(nProto, sSrcIP, nSrcPort, sDstIP, nDstPort)

    if tExisting then
        -- Already tracked
        if tExisting.sState == NFT.CT_NEW then
            -- Reply to a NEW connection → ESTABLISHED
            fConntrackUpdate(tExisting, NFT.CT_ESTABLISHED, tPkt.nLength)
            return NFT.CT_ESTABLISHED, tExisting
        end
        fConntrackUpdate(tExisting, tExisting.sState, tPkt.nLength)
        return tExisting.sState, tExisting
    end

    -- New connection
    local tNew = fConntrackInsert(nProto, sSrcIP, nSrcPort, sDstIP, nDstPort, NFT.CT_NEW)
    return NFT.CT_NEW, tNew
end

-- =============================================
-- NAT TABLE
-- =============================================

local g_tNATMappings = {}   -- [internal_key] → {external_ip, external_port}
local g_nNextNATPort = 10000

local function fNATAllocPort()
    g_nNextNATPort = g_nNextNATPort + 1
    if g_nNextNATPort > 60000 then g_nNextNATPort = 10000 end
    return g_nNextNATPort
end

-- =============================================
-- NFQUEUE — Userspace Packet Queue
-- =============================================

-- nfqueue state
local g_tNFQueues = {}   -- [nQueueNum] → {tPackets, hMQueue, nMaxLen}
local NFQUEUE_MAX_LEN    = 64

--- Create an nfqueue.
-- Userspace processes subscribe to queue numbers.
-- When a rule has action=QUEUE, the packet is placed here.
function NFT.createQueue(nQueueNum, nMaxLen)
    nMaxLen = nMaxLen or NFQUEUE_MAX_LEN

    -- Create a ke_ipc message queue for this nfqueue
    local hMQ = syscall("ke_create_mqueue", "nfq_" .. nQueueNum, nMaxLen, 8192)

    g_tNFQueues[nQueueNum] = {
        tPackets = {},
        hMQueue  = hMQ,
        nMaxLen  = nMaxLen,
        nTotal   = 0,
        nDropped = 0,
    }
    return true
end

--- Enqueue a packet for userspace processing.
-- Returns NF_STOLEN (packet ownership transferred to queue).
local function fNFQueueEnqueue(nQueueNum, tPktInfo)
    local tQ = g_tNFQueues[nQueueNum]
    if not tQ then return NFT.NF_DROP end  -- no queue → drop

    if #tQ.tPackets >= tQ.nMaxLen then
        tQ.nDropped = tQ.nDropped + 1
        return NFT.NF_DROP
    end

    -- Assign packet ID for tracking
    tQ.nTotal = tQ.nTotal + 1
    tPktInfo.nPacketId = tQ.nTotal
    tQ.tPackets[tPktInfo.nPacketId] = tPktInfo

    -- Send notification to userspace via message queue
    if tQ.hMQueue then
        local sMsg = string.format("PKT:%d:%d:%d",
            tPktInfo.nPacketId,
            tPktInfo.nLength or 0,
            tPktInfo.nProto or 0)
        pcall(syscall, "ke_mq_send", tQ.hMQueue, sMsg, 0)
    end

    return NFT.NF_STOLEN
end

--- Userspace verdict: accept, drop, or modify a queued packet.
-- @param nQueueNum   Queue number
-- @param nPacketId   Packet ID from the notification
-- @param nVerdict    NF_ACCEPT or NF_DROP
-- @param sModified   Optional: modified packet data (re-injected)
function NFT.queueVerdict(nQueueNum, nPacketId, nVerdict, sModified)
    local tQ = g_tNFQueues[nQueueNum]
    if not tQ then return false, "no such queue" end

    local tPktInfo = tQ.tPackets[nPacketId]
    if not tPktInfo then return false, "no such packet" end

    tQ.tPackets[nPacketId] = nil  -- remove from queue

    if sModified then
        tPktInfo.sModifiedData = sModified
    end

    tPktInfo.nVerdict = nVerdict
    return true, tPktInfo
end

--- Receive a packet from nfqueue (userspace side).
-- Blocks until a packet is available.
function NFT.queueReceive(nQueueNum, nTimeoutMs)
    local tQ = g_tNFQueues[nQueueNum]
    if not tQ or not tQ.hMQueue then return nil, "no queue" end

    local sMsg, nPri = syscall("ke_mq_receive", tQ.hMQueue, nTimeoutMs)
    if not sMsg then return nil, "timeout" end

    -- Parse "PKT:id:len:proto"
    local sId, sLen, sProto = sMsg:match("^PKT:(%d+):(%d+):(%d+)$")
    if not sId then return nil, "bad message" end

    local nPktId = tonumber(sId)
    local tPktInfo = tQ.tPackets[nPktId]
    if not tPktInfo then return nil, "packet expired" end

    return tPktInfo
end

--- Get the raw packet data from a queued packet for DPI.
-- Returns the lnqiobuf ring + descriptor for zero-copy access.
function NFT.queueGetData(tPktInfo)
    if not tPktInfo then return nil end
    return tPktInfo.tRing, tPktInfo.tDesc
end

-- =============================================
-- RULE MATCHING ENGINE
-- =============================================

local function fMatchField(vRule, vActual)
    if vRule == nil or vRule == "*" then return true end
    if type(vRule) == "table" then
        -- Range: {min, max}
        if vRule[1] and vRule[2] then
            return vActual >= vRule[1] and vActual <= vRule[2]
        end
        -- Set: {val1, val2, ...}
        for _, v in ipairs(vRule) do
            if v == vActual then return true end
        end
        return false
    end
    if type(vRule) == "string" and type(vActual) == "string" then
        if vRule:sub(-1) == "*" then
            return vActual:sub(1, #vRule - 1) == vRule:sub(1, -2)
        end
        -- Lua pattern match
        local bOk, bM = pcall(function()
            return vActual:match("^" .. vRule .. "$") ~= nil
        end)
        if bOk then return bM end
    end
    return tostring(vRule) == tostring(vActual)
end

--- Match a rule against a packet.
-- tRule fields: sProto, sSrcIP, sDstIP, nSrcPort, nDstPort,
--               nTcpFlags, sCtState, nMark, sIface
-- tPkt fields: nProto, sSrcIP, sDstIP, nSrcPort, nDstPort,
--              nTcpFlags, sCtState, nMark, sIface
local function fMatchRule(tRule, tPkt)
    if tRule.sProto and tRule.sProto ~= "*" then
        local nP = ({tcp=6, udp=17, icmp=1})[tRule.sProto] or tonumber(tRule.sProto)
        if nP and nP ~= tPkt.nProto then return false end
    end
    if not fMatchField(tRule.sSrcIP, tPkt.sSrcIP) then return false end
    if not fMatchField(tRule.sDstIP, tPkt.sDstIP) then return false end
    if not fMatchField(tRule.nSrcPort, tPkt.nSrcPort) then return false end
    if not fMatchField(tRule.nDstPort, tPkt.nDstPort) then return false end

    -- TCP flags match
    if tRule.nTcpFlags then
        if band(tPkt.nTcpFlags or 0, tRule.nTcpFlags) ~= tRule.nTcpFlags then
            return false
        end
    end

    -- Conntrack state match
    if tRule.sCtState and tRule.sCtState ~= "*" then
        if tPkt.sCtState ~= tRule.sCtState then return false end
    end

    -- Packet mark
    if tRule.nMark and tPkt.nMark ~= tRule.nMark then return false end

    -- Interface
    if tRule.sIface and tPkt.sIface ~= tRule.sIface then return false end

    -- Rate limiting (token bucket)
    if tRule._rateLimit then
        local tRL = tRule._rateLimit
        local nNow = os.clock()
        local nElapsed = nNow - tRL.nLastRefill
        tRL.nTokens = math.min(tRL.nBurst,
            tRL.nTokens + nElapsed * tRL.nRate)
        tRL.nLastRefill = nNow
        if tRL.nTokens < 1 then return false end
        tRL.nTokens = tRL.nTokens - 1
    end

    return true
end

-- =============================================
-- CHAIN AND TABLE MANAGEMENT
-- =============================================

local g_tTables = {}    -- [sTable][sChain] = {tRules, nPolicy}
local g_tHookChains = { -- hook → list of {sTable, sChain, nPriority}
    [NFT.HOOK_PREROUTING]  = {},
    [NFT.HOOK_INPUT]       = {},
    [NFT.HOOK_FORWARD]     = {},
    [NFT.HOOK_OUTPUT]      = {},
    [NFT.HOOK_POSTROUTING] = {},
}

function NFT.createTable(sName)
    if g_tTables[sName] then return false, "exists" end
    g_tTables[sName] = {}
    return true
end

function NFT.deleteTable(sName)
    g_tTables[sName] = nil
    -- Remove from hook registrations
    for _, tHook in pairs(g_tHookChains) do
        for i = #tHook, 1, -1 do
            if tHook[i].sTable == sName then
                table.remove(tHook, i)
            end
        end
    end
    return true
end

function NFT.createChain(sTable, sChain, tOpts)
    tOpts = tOpts or {}
    if not g_tTables[sTable] then
        NFT.createTable(sTable)
    end
    g_tTables[sTable][sChain] = {
        tRules  = {},
        nPolicy = tOpts.nPolicy or NFT.NF_ACCEPT,  -- default policy
    }

    -- Register with hook if specified
    if tOpts.nHook then
        local tEntry = {
            sTable   = sTable,
            sChain   = sChain,
            nPriority = tOpts.nPriority or 0,
        }
        local tHook = g_tHookChains[tOpts.nHook]
        tHook[#tHook + 1] = tEntry
        -- Sort by priority (lower = earlier)
        table.sort(tHook, function(a, b)
            return a.nPriority < b.nPriority
        end)
    end
    return true
end

function NFT.deleteChain(sTable, sChain)
    if g_tTables[sTable] then
        g_tTables[sTable][sChain] = nil
    end
    for _, tHook in pairs(g_tHookChains) do
        for i = #tHook, 1, -1 do
            if tHook[i].sTable == sTable and tHook[i].sChain == sChain then
                table.remove(tHook, i)
            end
        end
    end
    return true
end

--- Add a rule to a chain.
-- tRule = {
--     sProto, sSrcIP, sDstIP, nSrcPort, nDstPort,
--     nTcpFlags, sCtState, nMark, sIface,
--     sAction,    -- "accept", "drop", "reject", "log", "jump",
--                 -- "return", "snat", "dnat", "masquerade",
--                 -- "mark", "queue"
--     -- Action-specific:
--     sJumpChain,     -- for "jump"
--     sNATAddr,       -- for "snat"/"dnat" (IP address)
--     nNATPort,       -- for "snat"/"dnat" (port)
--     nQueueNum,      -- for "queue"
--     nMarkValue,     -- for "mark"
--     sComment,       -- human-readable
--     nRateLimit,     -- packets/sec (0 = unlimited)
--     nRateBurst,     -- burst size
-- }
function NFT.addRule(sTable, sChain, tRule)
    local tCh = g_tTables[sTable] and g_tTables[sTable][sChain]
    if not tCh then return false, "chain not found" end

    -- Initialize rate limiter if specified
    if tRule.nRateLimit and tRule.nRateLimit > 0 then
        tRule._rateLimit = {
            nRate       = tRule.nRateLimit,
            nBurst      = tRule.nRateBurst or tRule.nRateLimit,
            nTokens     = tRule.nRateBurst or tRule.nRateLimit,
            nLastRefill = os.clock(),
        }
    end

    -- Initialize counters
    tRule._nPackets = 0
    tRule._nBytes   = 0

    tCh.tRules[#tCh.tRules + 1] = tRule
    return true
end

function NFT.deleteRule(sTable, sChain, nIndex)
    local tCh = g_tTables[sTable] and g_tTables[sTable][sChain]
    if not tCh then return false end
    if nIndex < 1 or nIndex > #tCh.tRules then return false end
    table.remove(tCh.tRules, nIndex)
    return true
end

function NFT.flushChain(sTable, sChain)
    local tCh = g_tTables[sTable] and g_tTables[sTable][sChain]
    if tCh then tCh.tRules = {} end
    return true
end

-- =============================================
-- CHAIN EVALUATION
-- =============================================

local function fEvalChain(sTable, sChain, tPkt, nDepth)
    nDepth = nDepth or 0
    if nDepth > 8 then return NFT.NF_DROP end  -- prevent jump loops

    local tCh = g_tTables[sTable] and g_tTables[sTable][sChain]
    if not tCh then return NFT.NF_ACCEPT end

    for _, tRule in ipairs(tCh.tRules) do
        if fMatchRule(tRule, tPkt) then
            -- Update counters
            tRule._nPackets = (tRule._nPackets or 0) + 1
            tRule._nBytes   = (tRule._nBytes or 0) + (tPkt.nLength or 0)

            local sAction = tRule.sAction or "accept"

            if sAction == "accept" then
                return NFT.NF_ACCEPT

            elseif sAction == "drop" then
                return NFT.NF_DROP

            elseif sAction == "reject" then
                -- Like drop but sends ICMP unreachable back
                tPkt.bReject = true
                return NFT.NF_DROP

            elseif sAction == "log" then
                -- Log and continue processing
                tPkt.bLogged = true
                if tPkt.fLog then
                    tPkt.fLog(string.format(
                        "[NFT] %s/%s: %s %s:%d → %s:%d proto=%d",
                        sTable, sChain,
                        tRule.sComment or "LOG",
                        tPkt.sSrcIP or "?", tPkt.nSrcPort or 0,
                        tPkt.sDstIP or "?", tPkt.nDstPort or 0,
                        tPkt.nProto or 0))
                end
                -- Continue to next rule (log doesn't terminate)

            elseif sAction == "jump" then
                local nResult = fEvalChain(sTable, tRule.sJumpChain, tPkt, nDepth + 1)
                if nResult ~= NFT.NF_ACCEPT then return nResult end
                -- NF_ACCEPT from jumped chain → continue in current chain

            elseif sAction == "return" then
                return NFT.NF_ACCEPT  -- return to calling chain

            elseif sAction == "mark" then
                tPkt.nMark = tRule.nMarkValue or 0
                -- Continue processing

            elseif sAction == "snat" then
                -- Source NAT: rewrite source IP/port
                tPkt.tNAT = {
                    sType    = NFT.NAT_SNAT,
                    sOrigSrc = tPkt.sSrcIP,
                    nOrigPort = tPkt.nSrcPort,
                    sNewSrc  = tRule.sNATAddr,
                    nNewPort = tRule.nNATPort or fNATAllocPort(),
                }
                -- Update conntrack with NAT info
                if tPkt.tCTEntry then
                    tPkt.tCTEntry.tNAT = tPkt.tNAT
                end
                return NFT.NF_ACCEPT

            elseif sAction == "dnat" then
                -- Destination NAT: rewrite dest IP/port
                tPkt.tNAT = {
                    sType    = NFT.NAT_DNAT,
                    sOrigDst = tPkt.sDstIP,
                    nOrigPort = tPkt.nDstPort,
                    sNewDst  = tRule.sNATAddr,
                    nNewPort = tRule.nNATPort,
                }
                if tPkt.tCTEntry then
                    tPkt.tCTEntry.tNAT = tPkt.tNAT
                end
                return NFT.NF_ACCEPT

            elseif sAction == "masquerade" then
                -- Like SNAT but uses outgoing interface IP
                tPkt.tNAT = {
                    sType    = NFT.NAT_MASQUERADE,
                    sOrigSrc = tPkt.sSrcIP,
                    nOrigPort = tPkt.nSrcPort,
                    nNewPort = fNATAllocPort(),
                    -- sNewSrc filled by stack using outgoing interface IP
                }
                if tPkt.tCTEntry then
                    tPkt.tCTEntry.tNAT = tPkt.tNAT
                end
                return NFT.NF_ACCEPT

            elseif sAction == "queue" then
                -- Pass to nfqueue for userspace processing
                return fNFQueueEnqueue(tRule.nQueueNum or 0, {
                    tPkt    = tPkt,
                    tDesc   = tPkt.tDesc,
                    tRing   = tPkt.tRing,
                    nLength = tPkt.nLength,
                    nProto  = tPkt.nProto,
                    sTable  = sTable,
                    sChain  = sChain,
                })
            end
        end
    end

    -- No rule matched → apply chain policy
    return tCh.nPolicy
end

-- =============================================
-- HOOK PROCESSING (main entry point for stack)
-- =============================================

--- Process a packet through a hook point.
-- Called by the network stack at each processing stage.
--
-- @param nHook   Hook number (PREROUTING, INPUT, etc.)
-- @param tPkt    Packet info table:
--   {nProto, sSrcIP, sDstIP, nSrcPort, nDstPort,
--    nTcpFlags, nLength, sIface, nMark, sRaw,
--    tDesc (lnqiobuf), tRing (lnqiobuf)}
-- @return verdict (NF_ACCEPT, NF_DROP, NF_STOLEN)
function NFT.hook(nHook, tPkt)
    if not tPkt then return NFT.NF_DROP end

    -- Connection tracking (for all hooks)
    if not tPkt.sCtState then
        tPkt.sCtState, tPkt.tCTEntry = fGetConntrackState(tPkt)
    end

    -- Process all chains registered to this hook, in priority order
    local tChains = g_tHookChains[nHook]
    if not tChains then return NFT.NF_ACCEPT end

    for _, tChainRef in ipairs(tChains) do
        local nVerdict = fEvalChain(tChainRef.sTable, tChainRef.sChain, tPkt)
        if nVerdict ~= NFT.NF_ACCEPT then
            return nVerdict
        end
    end

    return NFT.NF_ACCEPT
end

-- =============================================
-- QUERY / STATS
-- =============================================

function NFT.listTables()
    local t = {}
    for sName in pairs(g_tTables) do t[#t + 1] = sName end
    table.sort(t)
    return t
end

function NFT.listChains(sTable)
    if not g_tTables[sTable] then return {} end
    local t = {}
    for sName, tCh in pairs(g_tTables[sTable]) do
        t[#t + 1] = {
            name    = sName,
            nRules  = #tCh.tRules,
            nPolicy = tCh.nPolicy,
        }
    end
    return t
end

function NFT.listRules(sTable, sChain)
    local tCh = g_tTables[sTable] and g_tTables[sTable][sChain]
    if not tCh then return {} end
    local t = {}
    for i, tR in ipairs(tCh.tRules) do
        t[i] = {
            index    = i,
            sAction  = tR.sAction,
            sProto   = tR.sProto,
            sSrcIP   = tR.sSrcIP,
            sDstIP   = tR.sDstIP,
            nSrcPort = tR.nSrcPort,
            nDstPort = tR.nDstPort,
            sCtState = tR.sCtState,
            nPackets = tR._nPackets or 0,
            nBytes   = tR._nBytes or 0,
            sComment = tR.sComment,
        }
    end
    return t
end

function NFT.getConntrack()
    local t = {}
    for _, e in pairs(g_tConntrack) do
        t[#t + 1] = {
            nProto   = e.nProto,
            sSrcIP   = e.sSrcIP,
            nSrcPort = e.nSrcPort,
            sDstIP   = e.sDstIP,
            nDstPort = e.nDstPort,
            sState   = e.sState,
            nPackets = e.nPackets,
            nBytes   = e.nBytes,
            nTTL     = math.max(0, math.floor(e.nExpiry - os.clock())),
            bHasNAT  = e.tNAT ~= nil,
        }
    end
    return t
end

function NFT.flushConntrack()
    g_tConntrack = {}
    return true
end

function NFT.getQueueStats(nQueueNum)
    local tQ = g_tNFQueues[nQueueNum]
    if not tQ then return nil end
    local nPending = 0
    for _ in pairs(tQ.tPackets) do nPending = nPending + 1 end
    return {
        nTotal   = tQ.nTotal,
        nDropped = tQ.nDropped,
        nPending = nPending,
        nMaxLen  = tQ.nMaxLen,
    }
end

--- Periodic maintenance: GC expired conntrack entries
function NFT.tick()
    fConntrackGC()
end

-- =============================================
-- CONVENIENCE: Setup default filter table
-- =============================================

function NFT.setupDefaults()
    -- Create standard tables
    NFT.createTable("filter")
    NFT.createTable("nat")
    NFT.createTable("mangle")

    -- Standard filter chains
    NFT.createChain("filter", "input", {
        nHook = NFT.HOOK_INPUT, nPriority = 0, nPolicy = NFT.NF_ACCEPT,
    })
    NFT.createChain("filter", "forward", {
        nHook = NFT.HOOK_FORWARD, nPriority = 0, nPolicy = NFT.NF_DROP,
    })
    NFT.createChain("filter", "output", {
        nHook = NFT.HOOK_OUTPUT, nPriority = 0, nPolicy = NFT.NF_ACCEPT,
    })

    -- NAT chains
    NFT.createChain("nat", "prerouting", {
        nHook = NFT.HOOK_PREROUTING, nPriority = -100, nPolicy = NFT.NF_ACCEPT,
    })
    NFT.createChain("nat", "postrouting", {
        nHook = NFT.HOOK_POSTROUTING, nPriority = 100, nPolicy = NFT.NF_ACCEPT,
    })

    -- Mangle chains
    NFT.createChain("mangle", "prerouting", {
        nHook = NFT.HOOK_PREROUTING, nPriority = -150, nPolicy = NFT.NF_ACCEPT,
    })

    return true
end

return NFT