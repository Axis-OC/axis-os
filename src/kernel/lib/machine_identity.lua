-- /lib/machine_identity.lua
-- Binds the OS installation to specific hardware.
-- Detects if someone copies the disk to another computer.

local crypto = require("crypto")
local oMachine = {}

local IDENTITY_FILE = "/etc/machine.id"

-- Generate a machine identity that's tied to THIS hardware
function oMachine.ComputeIdentity()
    local bOk = crypto.Init()
    if not bOk then return nil, "No data card" end
    
    -- Collect all hardware addresses
    local tAddrs = {}
    local bListOk, tList = pcall(function()
        local t = {}
        for addr, ctype in component.list() do t[#t+1] = ctype .. addr end
        return t
    end)
    if not bListOk then
        pcall(function()
            for addr, ctype in raw_component.list() do
                tAddrs[#tAddrs+1] = ctype .. addr
            end
        end)
    else
        tAddrs = tList
    end
    
    table.sort(tAddrs)
    local sFingerprint = table.concat(tAddrs, "|")
    
    -- Hash it
    return crypto.Encode64(crypto.SHA256(sFingerprint))
end

-- Check if current hardware matches stored identity
function oMachine.Verify()
    local fs = require("filesystem")
    
    local sCurrentId, sErr = oMachine.ComputeIdentity()
    if not sCurrentId then return nil, sErr end
    
    local h = fs.open(IDENTITY_FILE, "r")
    if not h then
        -- First boot on this hardware — store identity
        h = fs.open(IDENTITY_FILE, "w")
        if h then
            fs.write(h, sCurrentId)
            fs.close(h)
            fs.chmod(IDENTITY_FILE, 400)  -- read-only
            return true, "first_boot"
        end
        return nil, "Cannot write identity file"
    end
    
    local sStoredId = fs.read(h, math.huge)
    fs.close(h)
    
    if sStoredId == sCurrentId then
        return true, "verified"
    else
        return false, "HARDWARE MISMATCH: Disk may have been cloned to different machine"
    end
end

-- Monotonic boot counter (anti-replay)
-- Stored in EEPROM data area (survives disk cloning, tied to hardware)
function oMachine.IncrementBootCounter()
    local bOk, _ = pcall(function()
        local eep
        for addr in component.list("eeprom") do
            eep = component.proxy(addr)
            break
        end
        if not eep then return end
        
        local sData = eep.getData() or string.rep("\0", 256)
        
        -- Boot counter is at bytes 128-131 (big-endian uint32)
        local b1 = sData:byte(129) or 0
        local b2 = sData:byte(130) or 0
        local b3 = sData:byte(131) or 0
        local b4 = sData:byte(132) or 0
        local nCount = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
        
        nCount = nCount + 1
        
        -- Write back
        local sNew = sData:sub(1, 128) ..
                     string.char(math.floor(nCount / 16777216) % 256) ..
                     string.char(math.floor(nCount / 65536) % 256) ..
                     string.char(math.floor(nCount / 256) % 256) ..
                     string.char(nCount % 256) ..
                     sData:sub(133)
        
        eep.setData(sNew)
        return nCount
    end)
end

function oMachine.GetBootCount()
    local nCount = 0
    pcall(function()
        local eep
        for addr in component.list("eeprom") do
            eep = component.proxy(addr)
            break
        end
        if not eep then return end
        local sData = eep.getData() or ""
        if #sData >= 132 then
            nCount = (sData:byte(129) or 0) * 16777216 +
                     (sData:byte(130) or 0) * 65536 +
                     (sData:byte(131) or 0) * 256 +
                     (sData:byte(132) or 0)
        end
    end)
    return nCount
end

return oMachine