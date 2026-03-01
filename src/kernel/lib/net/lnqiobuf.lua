--
-- /lib/net/lnqiobuf.lua
-- AxisOS lnqiobuf — Local Over-Network Queued I/O Buffer
--
-- Analogous to Linux sk_buff / io_uring / AF_XDP.
-- Uses ke_ipc shared memory sections for zero-copy (or low-copy)
-- data transfer between the kernel network stack and applications.
--
-- Architecture:
--   The network stack stores received packet bytes in a shared
--   memory region (Lua table in ke_ipc KeCreateSection).
--   Applications map the section and read directly — no string
--   creation, no kernel IPC round-trip for data access.
--
-- Ring buffer model:
--   PRODUCER (NIC driver / stack) writes descriptors to the ring.
--   CONSUMER (application) reads descriptors and accesses data
--   from the shared region.  Completion is signalled via an
--   IPC event or IOCP post.
--
-- Packet data is stored as a contiguous byte array (Lua numbers)
-- in the shared memory table.  Descriptors point to offset+length
-- within this array.  Applications reconstruct strings only when
-- they actually need string operations.
--

local LNQIO = {}

-- =============================================
-- CONSTANTS
-- =============================================

LNQIO.DEFAULT_RING_SIZE    = 256     -- descriptor slots
LNQIO.DEFAULT_DATA_SIZE    = 65536   -- bytes in shared data region
LNQIO.MAX_PACKET_SIZE      = 8192
LNQIO.DESCRIPTOR_FIELDS    = 8       -- fields per descriptor

-- Descriptor flags
LNQIO.DESC_F_VALID      = 0x01
LNQIO.DESC_F_EOP        = 0x02   -- End Of Packet
LNQIO.DESC_F_SOP        = 0x04   -- Start Of Packet
LNQIO.DESC_F_CONSUMED   = 0x08   -- Consumer has processed this
LNQIO.DESC_F_IP_CSUM_OK = 0x10   -- IP checksum verified
LNQIO.DESC_F_L4_CSUM_OK = 0x20   -- TCP/UDP checksum verified
LNQIO.DESC_F_FRAGMENT   = 0x40   -- This is a fragment

-- Ring states
LNQIO.RING_STATE_IDLE   = 0
LNQIO.RING_STATE_ACTIVE = 1
LNQIO.RING_STATE_FULL   = 2

-- =============================================
-- SHARED MEMORY LAYOUT
--
-- The shared section's tData table contains:
--
-- tData.meta = {
--     nRingSize,       -- number of descriptor slots
--     nDataSize,       -- size of data region in bytes
--     nProducerIdx,    -- next write position (producer)
--     nConsumerIdx,    -- next read position (consumer)
--     nDataWritePos,   -- next byte position in data region
--     nState,          -- ring state
--     nTotalRx,        -- total packets received
--     nTotalBytes,     -- total bytes received
--     nDropped,        -- packets dropped (ring full)
--     nErrors,         -- checksum errors etc.
-- }
--
-- tData.ring = {
--     [1..nRingSize] = {
--         nOffset,      -- byte offset in data region
--         nLength,      -- packet length in bytes
--         nFlags,       -- descriptor flags
--         nProto,       -- IP protocol number
--         nSrcIP,       -- source IP as u32
--         nDstIP,       -- destination IP as u32
--         nSrcPort,     -- source port (TCP/UDP)
--         nDstPort,     -- destination port (TCP/UDP)
--     }
-- }
--
-- tData.data = {
--     [1..nDataSize] = byte values (numbers 0-255)
-- }
-- =============================================

-- =============================================
-- RING BUFFER CREATION
-- Creates a shared memory section with the ring
-- buffer layout.  Returns handle for both producer
-- and consumer to map.
-- =============================================

--- Create a new lnqiobuf ring in shared memory.
-- @param sName     Section name for ke_ipc
-- @param nRingSize Number of descriptor slots (default 256)
-- @param nDataSize Byte capacity of data region (default 64KB)
-- @return tRing handle, or nil + error
function LNQIO.create(sName, nRingSize, nDataSize)
    nRingSize = nRingSize or LNQIO.DEFAULT_RING_SIZE
    nDataSize = nDataSize or LNQIO.DEFAULT_DATA_SIZE

    -- Create shared memory section via syscall
    local hSection = syscall("ke_create_section", sName,
        nRingSize * LNQIO.DESCRIPTOR_FIELDS + nDataSize + 256)
    if not hSection then
        return nil, "failed to create section: " .. tostring(sName)
    end

    -- Map the section to get the shared table
    local tData = syscall("ke_map_section", hSection)
    if not tData then
        return nil, "failed to map section"
    end

    -- Initialize the ring buffer structure
    tData.meta = {
        nRingSize    = nRingSize,
        nDataSize    = nDataSize,
        nProducerIdx = 1,
        nConsumerIdx = 1,
        nDataWritePos = 1,
        nState       = LNQIO.RING_STATE_IDLE,
        nTotalRx     = 0,
        nTotalBytes  = 0,
        nDropped     = 0,
        nErrors      = 0,
        nOverruns    = 0,
    }

    -- Pre-allocate ring descriptor slots
    tData.ring = {}
    for i = 1, nRingSize do
        tData.ring[i] = {
            nOffset  = 0,
            nLength  = 0,
            nFlags   = 0,
            nProto   = 0,
            nSrcIP   = 0,
            nDstIP   = 0,
            nSrcPort = 0,
            nDstPort = 0,
        }
    end

    -- Pre-allocate data region
    tData.data = {}

    local tRing = {
        hSection  = hSection,
        tData     = tData,
        sName     = sName,
        _isOwner  = true,
    }

    return setmetatable(tRing, {__index = LNQIO._Ring})
end

--- Open an existing lnqiobuf ring (consumer side).
function LNQIO.open(sName)
    local hSection = syscall("ke_open_section", sName)
    if not hSection then
        return nil, "section not found: " .. tostring(sName)
    end

    local tData = syscall("ke_map_section", hSection)
    if not tData or not tData.meta then
        return nil, "invalid ring buffer section"
    end

    local tRing = {
        hSection  = hSection,
        tData     = tData,
        sName     = sName,
        _isOwner  = false,
    }

    return setmetatable(tRing, {__index = LNQIO._Ring})
end

-- =============================================
-- RING BUFFER OPERATIONS
-- =============================================

LNQIO._Ring = {}

--- PRODUCER: Enqueue a packet into the ring buffer.
-- The packet data is stored as individual bytes in the
-- shared data region.  A descriptor is written to the ring.
--
-- @param sPacket  Raw packet bytes (string)
-- @param tMeta    Optional metadata {nProto, nSrcIP, nDstIP, nSrcPort, nDstPort, nFlags}
-- @return true on success, false if ring full
function LNQIO._Ring:produce(sPacket, tMeta)
    local tD = self.tData
    local tM = tD.meta
    tMeta = tMeta or {}

    -- Check if ring is full
    local nNext = (tM.nProducerIdx % tM.nRingSize) + 1
    if nNext == tM.nConsumerIdx then
        tM.nDropped = tM.nDropped + 1
        tM.nState = LNQIO.RING_STATE_FULL
        return false
    end

    local nPktLen = #sPacket
    if nPktLen > LNQIO.MAX_PACKET_SIZE then
        tM.nErrors = tM.nErrors + 1
        return false, "packet too large"
    end

    -- Check data region space (circular)
    local nDataPos = tM.nDataWritePos
    if nDataPos + nPktLen > tM.nDataSize then
        -- Wrap around
        nDataPos = 1
    end

    -- Copy packet bytes into shared data region
    -- This is the ONE copy we make (modem string → shared byte array)
    local tDataRegion = tD.data
    for i = 1, nPktLen do
        tDataRegion[nDataPos + i - 1] = sPacket:byte(i)
    end

    -- Write descriptor
    local tDesc = tD.ring[tM.nProducerIdx]
    tDesc.nOffset  = nDataPos
    tDesc.nLength  = nPktLen
    tDesc.nFlags   = bit32.bor(LNQIO.DESC_F_VALID, LNQIO.DESC_F_SOP,
                               LNQIO.DESC_F_EOP, tMeta.nFlags or 0)
    tDesc.nProto   = tMeta.nProto or 0
    tDesc.nSrcIP   = tMeta.nSrcIP or 0
    tDesc.nDstIP   = tMeta.nDstIP or 0
    tDesc.nSrcPort = tMeta.nSrcPort or 0
    tDesc.nDstPort = tMeta.nDstPort or 0

    -- Advance producer index
    tM.nDataWritePos = nDataPos + nPktLen
    if tM.nDataWritePos > tM.nDataSize then
        tM.nDataWritePos = 1
    end
    tM.nProducerIdx = nNext
    tM.nState = LNQIO.RING_STATE_ACTIVE

    -- Update stats
    tM.nTotalRx = tM.nTotalRx + 1
    tM.nTotalBytes = tM.nTotalBytes + nPktLen

    return true
end

--- CONSUMER: Peek at the next available descriptor without consuming.
-- @return descriptor table, or nil if ring empty
function LNQIO._Ring:peek()
    local tD = self.tData
    local tM = tD.meta

    if tM.nConsumerIdx == tM.nProducerIdx then
        return nil  -- empty
    end

    local tDesc = tD.ring[tM.nConsumerIdx]
    if bit32.band(tDesc.nFlags, LNQIO.DESC_F_VALID) == 0 then
        return nil
    end

    return tDesc
end

--- CONSUMER: Consume (dequeue) the next descriptor.
-- Returns the descriptor; caller reads data from shared region.
-- @return descriptor table, or nil if empty
function LNQIO._Ring:consume()
    local tD = self.tData
    local tM = tD.meta

    if tM.nConsumerIdx == tM.nProducerIdx then
        return nil
    end

    local tDesc = tD.ring[tM.nConsumerIdx]
    if bit32.band(tDesc.nFlags, LNQIO.DESC_F_VALID) == 0 then
        return nil
    end

    -- Mark as consumed
    tDesc.nFlags = bit32.bor(tDesc.nFlags, LNQIO.DESC_F_CONSUMED)

    -- Advance consumer index
    tM.nConsumerIdx = (tM.nConsumerIdx % tM.nRingSize) + 1
    if tM.nConsumerIdx == tM.nProducerIdx then
        tM.nState = LNQIO.RING_STATE_IDLE
    end

    return tDesc
end

--- Read packet data from shared region as a string.
-- This materializes the bytes into a Lua string — call only
-- when you actually need string operations on the data.
-- For inspection (DPI), use readByte() instead.
-- @param tDesc  Descriptor from consume() or peek()
-- @return packet data as string
function LNQIO._Ring:materialize(tDesc)
    if not tDesc then return nil end
    local tDataRegion = self.tData.data
    local tChars = {}
    for i = 0, tDesc.nLength - 1 do
        tChars[i + 1] = string.char(tDataRegion[tDesc.nOffset + i] or 0)
    end
    return table.concat(tChars)
end

--- Read a single byte from the data region without materialization.
-- For DPI: inspect individual bytes without creating strings.
-- @param tDesc  Descriptor
-- @param nIdx   Byte index (1-based relative to packet start)
-- @return byte value (0-255)
function LNQIO._Ring:readByte(tDesc, nIdx)
    if not tDesc or nIdx < 1 or nIdx > tDesc.nLength then return nil end
    return self.tData.data[tDesc.nOffset + nIdx - 1]
end

--- Read a 16-bit big-endian value from the data region.
function LNQIO._Ring:readU16(tDesc, nIdx)
    local b1 = self:readByte(tDesc, nIdx)
    local b2 = self:readByte(tDesc, nIdx + 1)
    if not b1 or not b2 then return nil end
    return b1 * 256 + b2
end

--- Read a 32-bit big-endian value from the data region.
function LNQIO._Ring:readU32(tDesc, nIdx)
    local b1 = self:readByte(tDesc, nIdx)
    local b2 = self:readByte(tDesc, nIdx + 1)
    local b3 = self:readByte(tDesc, nIdx + 2)
    local b4 = self:readByte(tDesc, nIdx + 3)
    if not b1 then return nil end
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

--- Write a byte into the data region (for packet modification).
function LNQIO._Ring:writeByte(tDesc, nIdx, nVal)
    if not tDesc or nIdx < 1 or nIdx > tDesc.nLength then return false end
    self.tData.data[tDesc.nOffset + nIdx - 1] = bit32.band(nVal, 0xFF)
    return true
end

--- Write a 16-bit big-endian value.
function LNQIO._Ring:writeU16(tDesc, nIdx, nVal)
    self:writeByte(tDesc, nIdx, bit32.rshift(nVal, 8))
    self:writeByte(tDesc, nIdx + 1, bit32.band(nVal, 0xFF))
    return true
end

--- Batch consume: drain up to N descriptors at once.
-- Returns array of descriptors.
function LNQIO._Ring:consumeBatch(nMax)
    nMax = nMax or 32
    local tBatch = {}
    for _ = 1, nMax do
        local tDesc = self:consume()
        if not tDesc then break end
        tBatch[#tBatch + 1] = tDesc
    end
    return tBatch
end

--- Get the number of pending (unconsumed) descriptors.
function LNQIO._Ring:pending()
    local tM = self.tData.meta
    local nProd = tM.nProducerIdx
    local nCons = tM.nConsumerIdx
    if nProd >= nCons then
        return nProd - nCons
    else
        return tM.nRingSize - nCons + nProd
    end
end

--- Get ring statistics.
function LNQIO._Ring:stats()
    local tM = self.tData.meta
    return {
        nRingSize    = tM.nRingSize,
        nDataSize    = tM.nDataSize,
        nPending     = self:pending(),
        nTotalRx     = tM.nTotalRx,
        nTotalBytes  = tM.nTotalBytes,
        nDropped     = tM.nDropped,
        nErrors      = tM.nErrors,
        nOverruns    = tM.nOverruns,
        nState       = tM.nState,
        nProducerIdx = tM.nProducerIdx,
        nConsumerIdx = tM.nConsumerIdx,
    }
end

return LNQIO