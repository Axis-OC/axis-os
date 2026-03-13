--
-- /lib/hypervisor.lua
-- AxisOS Metatable Hypervisor
--
-- Provides tamper-evident, read-only protection for kernel data structures.
--
-- Protection model:
--   1. freeze(t)   → empty proxy; __index reads from sealed copy,
--                     __newindex blocks writes, __metatable hides the real mt
--   2. snapshot(t)  → structural fingerprint (function identities + key sets)
--   3. verify(t, s) → compare current state against snapshot
--
-- Why this works:
--   - Ring 2.5+ sandboxes have NO rawset/rawget (removed from sandbox)
--   - Ring 2 HAS rawset, but rawset(proxy, k, v) only adds to the proxy
--     table, NOT to the sealed backing copy — reads still go through
--     __index → frozen data.  PatchGuard detects proxy pollution.
--   - __metatable = "hypervisor_sealed" blocks getmetatable(proxy)
--     and makes setmetatable(proxy, ...) error.
--   - The frozen data lives in a closure upvalue — no code path
--     reaches it without the original table reference (held only by Ring 0).
--

local HV = {}

-- =============================================
-- FREEZE: Immutable read-only proxy
-- =============================================

function HV.freeze(tOriginal, sName)
    local tFrozen = {}
    for k, v in pairs(tOriginal) do
        tFrozen[k] = v
    end

    local proxy = {}
    setmetatable(proxy, {
        __index = function(_, key)
            return tFrozen[key]
        end,
        __newindex = function(_, key, _)
            error(string.format(
                "HVCI VIOLATION: Write to sealed '%s.%s' blocked",
                sName or "?", tostring(key)), 2)
        end,
        __metatable = "hypervisor_sealed",
        __pairs = function()
            return next, tFrozen, nil
        end,
    })

    return proxy, tFrozen
end

-- =============================================
-- SNAPSHOT: Structural fingerprint
-- =============================================

function HV.snapshot(tTable, sName)
    local tSnap = {
        _name    = sName or "?",
        _time    = 0,
        _entries = {},
        _keyList = {},
        _keyFP   = "",
    }
    pcall(function() tSnap._time = raw_computer.uptime() end)

    local tKeys = {}
    for k, v in pairs(tTable) do
        local sType = type(v)
        local sEntry
        if sType == "function" then
            sEntry = "F:" .. tostring(v)
        elseif sType == "table" then
            local n, tSub = 0, {}
            for sk in pairs(v) do
                n = n + 1
                if n <= 8 then tSub[n] = tostring(sk) end
            end
            table.sort(tSub)
            sEntry = "T:" .. n .. ":" .. table.concat(tSub, ",")
        else
            sEntry = sType .. ":" .. tostring(v)
        end
        tSnap._entries[tostring(k)] = sEntry
        tKeys[#tKeys + 1] = tostring(k)
    end
    table.sort(tKeys)
    tSnap._keyList = tKeys
    tSnap._keyFP   = table.concat(tKeys, "|")
    return tSnap
end

-- =============================================
-- VERIFY: Compare current state to snapshot
-- =============================================

function HV.verify(tTable, tSnap)
    if not tSnap or not tSnap._entries then
        return false, {{check = "NO_SNAPSHOT"}}
    end
    local tV = {}

    for sKey, sExp in pairs(tSnap._entries) do
        local v = tTable[sKey]
        local sCur
        if v == nil then sCur = "nil"
        elseif type(v) == "function" then sCur = "F:" .. tostring(v)
        elseif type(v) == "table" then
            local n, tS = 0, {}
            for sk in pairs(v) do n=n+1; if n<=8 then tS[n]=tostring(sk) end end
            table.sort(tS)
            sCur = "T:" .. n .. ":" .. table.concat(tS, ",")
        else sCur = type(v) .. ":" .. tostring(v) end

        if sCur ~= sExp then
            tV[#tV+1] = {check="MODIFIED", key=sKey,
                          expected=sExp:sub(1,40), actual=sCur:sub(1,40)}
        end
    end

    local tCK = {}
    for k in pairs(tTable) do tCK[#tCK+1] = tostring(k) end
    table.sort(tCK)
    if table.concat(tCK, "|") ~= tSnap._keyFP then
        local tES = {}
        for _, k in ipairs(tSnap._keyList) do tES[k] = true end
        local tCS = {}
        for _, k in ipairs(tCK) do tCS[k] = true end
        for _, k in ipairs(tCK) do
            if not tES[k] then tV[#tV+1] = {check="KEY_ADDED", key=k} end
        end
        for _, k in ipairs(tSnap._keyList) do
            if not tCS[k] then tV[#tV+1] = {check="KEY_REMOVED", key=k} end
        end
    end

    return #tV == 0, tV
end

-- =============================================
-- MONITOR: Auditing proxy (write-through + callback)
-- =============================================

function HV.monitor(tOriginal, sName, fCb)
    local proxy = {}
    setmetatable(proxy, {
        __index = tOriginal,
        __newindex = function(_, key, value)
            if fCb then fCb(sName, tostring(key), tOriginal[key], value) end
            tOriginal[key] = value
        end,
        __metatable = "hypervisor_monitored",
        __pairs = function() return next, tOriginal, nil end,
    })
    return proxy
end

return HV