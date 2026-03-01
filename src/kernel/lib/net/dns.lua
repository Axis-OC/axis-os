--
-- /lib/net/dns.lua
-- AxisOS DNS Resolver — RFC 1035 Wire Format
--
-- Implements DNS query building, response parsing, caching,
-- and resolution over both the IP stack (UDP) and HTTP (DoH).
--

local DNS = {}

-- =============================================
-- CONSTANTS
-- =============================================

DNS.PORT          = 53
DNS.MAX_PACKET    = 512    -- standard DNS UDP max
DNS.DEFAULT_TTL   = 300    -- 5 min cache default
DNS.CACHE_MAX     = 128

-- Record types
DNS.TYPE_A     = 1
DNS.TYPE_NS    = 2
DNS.TYPE_CNAME = 5
DNS.TYPE_SOA   = 6
DNS.TYPE_PTR   = 12
DNS.TYPE_MX    = 15
DNS.TYPE_TXT   = 16
DNS.TYPE_AAAA  = 28
DNS.TYPE_SRV   = 33

-- Classes
DNS.CLASS_IN = 1

-- Response codes
DNS.RCODE_OK       = 0
DNS.RCODE_FORMAT   = 1
DNS.RCODE_SERVFAIL = 2
DNS.RCODE_NXDOMAIN = 3
DNS.RCODE_NOTIMP   = 4
DNS.RCODE_REFUSED  = 5

DNS.RCODE_NAMES = {
    [0] = "NOERROR", [1] = "FORMERR", [2] = "SERVFAIL",
    [3] = "NXDOMAIN", [4] = "NOTIMP", [5] = "REFUSED",
}

DNS.TYPE_NAMES = {
    [1] = "A", [2] = "NS", [5] = "CNAME", [6] = "SOA",
    [12] = "PTR", [15] = "MX", [16] = "TXT", [28] = "AAAA",
    [33] = "SRV",
}

-- =============================================
-- BINARY HELPERS (big-endian)
-- =============================================

local function u16(n) return string.char(math.floor(n/256)%256, n%256) end
local function u32(n)
    return string.char(math.floor(n/16777216)%256, math.floor(n/65536)%256,
                       math.floor(n/256)%256, n%256)
end
local function r16(s, o) o=o or 1; return s:byte(o)*256 + s:byte(o+1) end
local function r32(s, o) o=o or 1
    return s:byte(o)*16777216 + s:byte(o+1)*65536 + s:byte(o+2)*256 + s:byte(o+3)
end

-- =============================================
-- DOMAIN NAME ENCODING / DECODING
-- =============================================

--- Encode "www.example.com" → "\3www\7example\3com\0"
function DNS.encodeName(sDomain)
    local tParts = {}
    for sLabel in (sDomain .. "."):gmatch("([^%.]+)%.") do
        if #sLabel > 63 then return nil, "label too long" end
        tParts[#tParts + 1] = string.char(#sLabel) .. sLabel
    end
    return table.concat(tParts) .. "\0"
end

--- Decode name from DNS packet at offset nPos (handles compression pointers)
--- Returns: name string, new offset after name
function DNS.decodeName(sPacket, nPos)
    local tLabels = {}
    local nJumped = nil  -- track first jump for final offset
    local nSafety = 0

    while nPos <= #sPacket and nSafety < 64 do
        nSafety = nSafety + 1
        local nLen = sPacket:byte(nPos)

        if nLen == 0 then
            -- End of name
            if not nJumped then nJumped = nPos + 1 end
            break

        elseif bit32.band(nLen, 0xC0) == 0xC0 then
            -- Compression pointer: 2 bytes, offset into packet
            if not nJumped then nJumped = nPos + 2 end
            local nPtr = bit32.band(r16(sPacket, nPos), 0x3FFF)
            nPos = nPtr + 1  -- DNS offsets are 0-based, Lua strings 1-based
        else
            -- Normal label
            tLabels[#tLabels + 1] = sPacket:sub(nPos + 1, nPos + nLen)
            nPos = nPos + nLen + 1
        end
    end

    return table.concat(tLabels, "."), nJumped or nPos
end

-- =============================================
-- QUERY BUILDING
-- =============================================

--- Build a DNS query packet
-- @param sDomain  Domain to resolve (e.g. "example.com")
-- @param nType    Record type (DNS.TYPE_A, etc.)
-- @param nId      Transaction ID (random 16-bit)
-- @return binary packet string
function DNS.buildQuery(sDomain, nType, nId)
    nType = nType or DNS.TYPE_A
    nId   = nId or math.random(0, 0xFFFF)

    -- Header: ID, Flags (RD=1), QDCOUNT=1, ANCOUNT=0, NSCOUNT=0, ARCOUNT=0
    local nFlags = 0x0100   -- QR=0, Opcode=0, AA=0, TC=0, RD=1, RA=0, Z=0, RCODE=0
    local sHeader = u16(nId) .. u16(nFlags)
                 .. u16(1) .. u16(0) .. u16(0) .. u16(0)

    -- Question section
    local sName, sNameErr = DNS.encodeName(sDomain)
    if not sName then return nil, sNameErr end

    local sQuestion = sName .. u16(nType) .. u16(DNS.CLASS_IN)

    return sHeader .. sQuestion, nId
end

-- =============================================
-- RESPONSE PARSING
-- =============================================

--- Parse a DNS response packet
-- @param sPacket  Raw DNS response bytes
-- @return table with header, questions, answers, authority, additional
function DNS.parseResponse(sPacket)
    if not sPacket or #sPacket < 12 then
        return nil, "packet too short"
    end

    local tResult = {
        nId      = r16(sPacket, 1),
        nFlags   = r16(sPacket, 3),
        bQR      = bit32.band(r16(sPacket, 3), 0x8000) ~= 0,
        nOpcode  = bit32.band(bit32.rshift(r16(sPacket, 3), 11), 0x0F),
        bAA      = bit32.band(r16(sPacket, 3), 0x0400) ~= 0,
        bTC      = bit32.band(r16(sPacket, 3), 0x0200) ~= 0,
        bRD      = bit32.band(r16(sPacket, 3), 0x0100) ~= 0,
        bRA      = bit32.band(r16(sPacket, 3), 0x0080) ~= 0,
        nRcode   = bit32.band(r16(sPacket, 3), 0x000F),
        nQDCount = r16(sPacket, 5),
        nANCount = r16(sPacket, 7),
        nNSCount = r16(sPacket, 9),
        nARCount = r16(sPacket, 11),
        tQuestions  = {},
        tAnswers    = {},
        tAuthority  = {},
        tAdditional = {},
    }
    tResult.sRcodeName = DNS.RCODE_NAMES[tResult.nRcode] or "UNKNOWN"

    local nPos = 13  -- after 12-byte header

    -- Parse questions
    for _ = 1, tResult.nQDCount do
        if nPos > #sPacket then break end
        local sName, nNewPos = DNS.decodeName(sPacket, nPos)
        nPos = nNewPos
        if nPos + 3 > #sPacket then break end
        local nQType  = r16(sPacket, nPos)
        local nQClass = r16(sPacket, nPos + 2)
        nPos = nPos + 4
        tResult.tQuestions[#tResult.tQuestions + 1] = {
            sName = sName, nType = nQType, nClass = nQClass,
        }
    end

    -- Parse resource records (answers, authority, additional)
    local function parseRR(nCount)
        local tRecords = {}
        for _ = 1, nCount do
            if nPos > #sPacket then break end
            local sName, nNewPos = DNS.decodeName(sPacket, nPos)
            nPos = nNewPos
            if nPos + 9 > #sPacket then break end

            local nType   = r16(sPacket, nPos)
            local nClass  = r16(sPacket, nPos + 2)
            local nTTL    = r32(sPacket, nPos + 4)
            local nRDLen  = r16(sPacket, nPos + 8)
            nPos = nPos + 10

            local sRData = sPacket:sub(nPos, nPos + nRDLen - 1)
            local tRR = {
                sName    = sName,
                nType    = nType,
                sType    = DNS.TYPE_NAMES[nType] or tostring(nType),
                nClass   = nClass,
                nTTL     = nTTL,
                nRDLen   = nRDLen,
                sRData   = sRData,
            }

            -- Decode RDATA for common types
            if nType == DNS.TYPE_A and nRDLen == 4 then
                tRR.sAddress = string.format("%d.%d.%d.%d",
                    sRData:byte(1), sRData:byte(2),
                    sRData:byte(3), sRData:byte(4))
            elseif nType == DNS.TYPE_CNAME or nType == DNS.TYPE_NS
                   or nType == DNS.TYPE_PTR then
                tRR.sTarget = DNS.decodeName(sPacket, nPos - nRDLen)
            elseif nType == DNS.TYPE_MX and nRDLen >= 4 then
                tRR.nPreference = r16(sRData, 1)
                tRR.sExchange = DNS.decodeName(sPacket, nPos - nRDLen + 2)
            elseif nType == DNS.TYPE_TXT and nRDLen >= 1 then
                local nTxtLen = sRData:byte(1)
                tRR.sText = sRData:sub(2, 1 + nTxtLen)
            end

            nPos = nPos + nRDLen
            tRecords[#tRecords + 1] = tRR
        end
        return tRecords
    end

    tResult.tAnswers    = parseRR(tResult.nANCount)
    tResult.tAuthority  = parseRR(tResult.nNSCount)
    tResult.tAdditional = parseRR(tResult.nARCount)

    return tResult
end

-- =============================================
-- CACHE
-- =============================================

local g_tCache = {}  -- [domain..":"..type] → {tRecords, nExpiry}

function DNS.cacheSet(sDomain, nType, tRecords, nTTL)
    nTTL = nTTL or DNS.DEFAULT_TTL
    local sKey = sDomain:lower() .. ":" .. nType
    g_tCache[sKey] = {
        tRecords = tRecords,
        nExpiry  = os.clock() + nTTL,
    }
    -- Evict if over limit
    local nCount = 0
    for _ in pairs(g_tCache) do nCount = nCount + 1 end
    if nCount > DNS.CACHE_MAX then
        local sOldest, nOldestTime = nil, math.huge
        for k, v in pairs(g_tCache) do
            if v.nExpiry < nOldestTime then
                sOldest = k; nOldestTime = v.nExpiry
            end
        end
        if sOldest then g_tCache[sOldest] = nil end
    end
end

function DNS.cacheGet(sDomain, nType)
    local sKey = sDomain:lower() .. ":" .. nType
    local tEntry = g_tCache[sKey]
    if not tEntry then return nil end
    if os.clock() > tEntry.nExpiry then
        g_tCache[sKey] = nil
        return nil
    end
    return tEntry.tRecords
end

function DNS.cacheClear()
    g_tCache = {}
end

function DNS.cacheStats()
    local nEntries, nExpired = 0, 0
    local nNow = os.clock()
    for _, v in pairs(g_tCache) do
        nEntries = nEntries + 1
        if nNow > v.nExpiry then nExpired = nExpired + 1 end
    end
    return { nEntries = nEntries, nExpired = nExpired, nMax = DNS.CACHE_MAX }
end

-- =============================================
-- RESOLVER — HTTP-based (DoH) for internet card
-- Falls back to this when no modem IP stack available
-- =============================================

function DNS.resolveHTTP(sDomain, nType)
    nType = nType or DNS.TYPE_A

    -- Check cache first
    local tCached = DNS.cacheGet(sDomain, nType)
    if tCached then return tCached end

    -- Use Cloudflare DoH JSON API
    local sTypeName = DNS.TYPE_NAMES[nType] or "A"
    local sUrl = "https://cloudflare-dns.com/dns-query?name="
              .. sDomain .. "&type=" .. sTypeName

    local bOk, oHttp = pcall(require, "http")
    if not bOk then return nil, "http library not available" end

    local tResp = oHttp.get(sUrl, {
        ["Accept"] = "application/dns-json",
    })

    if not tResp or tResp.code ~= 200 or not tResp.body then
        return nil, "DoH request failed: " .. tostring(tResp and tResp.code)
    end

    -- Parse JSON response (minimal parser for DNS JSON format)
    local tRecords = {}
    local sBody = tResp.body

    -- Extract Answer records: "data":"1.2.3.4","type":1,"TTL":300
    for sData, sType, sTTL in sBody:gmatch(
        '"data"%s*:%s*"([^"]+)"%s*,%s*"type"%s*:%s*(%d+)%s*,%s*"TTL"%s*:%s*(%d+)') do
        tRecords[#tRecords + 1] = {
            sName    = sDomain,
            nType    = tonumber(sType),
            sType    = DNS.TYPE_NAMES[tonumber(sType)] or sType,
            sAddress = sData,
            sTarget  = sData,
            sText    = sData,
            nTTL     = tonumber(sTTL) or DNS.DEFAULT_TTL,
        }
    end

    -- Also try: "data":"1.2.3.4" with "name":"..." pattern
    if #tRecords == 0 then
        for sData in sBody:gmatch('"data"%s*:%s*"([^"]+)"') do
            tRecords[#tRecords + 1] = {
                sName    = sDomain,
                nType    = nType,
                sType    = sTypeName,
                sAddress = sData,
                sTarget  = sData,
                nTTL     = DNS.DEFAULT_TTL,
            }
        end
    end

    if #tRecords > 0 then
        DNS.cacheSet(sDomain, nType, tRecords, tRecords[1].nTTL)
    end

    return tRecords
end

--- High-level resolve: returns first A record IP or nil
function DNS.resolve(sDomain, nType)
    nType = nType or DNS.TYPE_A
    local tRecords, sErr = DNS.resolveHTTP(sDomain, nType)
    if not tRecords or #tRecords == 0 then
        return nil, sErr or "no records"
    end
    return tRecords[1].sAddress or tRecords[1].sTarget, tRecords
end

--- Reverse DNS: IP → domain name (PTR record)
function DNS.reverse(sIP)
    local a, b, c, d = sIP:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil, "invalid IP" end
    local sPtrDomain = d .. "." .. c .. "." .. b .. "." .. a .. ".in-addr.arpa"
    return DNS.resolve(sPtrDomain, DNS.TYPE_PTR)
end

return DNS