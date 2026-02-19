--
-- /lib/preempt.lua
--
-- Injects yield-checkpoint calls (__pc()) into Lua source at loop and
-- branch boundaries.
--
-- Injection points (after keyword + whitespace):
--   do   →  every for/while/do-block iteration
--   then →  every if/elseif branch entry
--   repeat → every repeat-until iteration
--   else →  every else branch entry  (but NOT "elseif")
--
-- The scanner correctly skips:
--   • single-quoted and double-quoted string literals
--   • long strings  [[ ]], [=[ ]=], etc.
--   • short comments  --
--   • long comments   --[[ ]], --[=[ ]=], etc.
--
-- Identifiers containing keywords (do_something, redo, etc.) are
-- protected by word-boundary checks on both sides.
--

local oPreempt = {}

-- =============================================
-- CONFIGURATION
-- =============================================

-- Time quantum per process slice (seconds).
-- A process that has been running for longer than this since its last
-- yield will be preempted at the next __pc() call.
oPreempt.DEFAULT_QUANTUM = 0.05   -- 50 ms

-- __pc() call-count threshold.  We only read the wall clock every N
-- calls to avoid the overhead of computer.uptime() on every loop
-- iteration.  Higher = less overhead, slightly less responsive.
oPreempt.CHECK_INTERVAL = 128

-- =============================================
-- STATISTICS  (read by the kernel for diagnostics)
-- =============================================

oPreempt.nTotalInstrumented = 0
oPreempt.nTotalInjections   = 0

-- =============================================
-- SOURCE CODE INSTRUMENTER
-- =============================================

function oPreempt.instrument(sCode, sLabel)
    if not sCode or #sCode == 0 then return sCode, 0 end

    local sCheckName = string.format("_pc_%04x%04x",
        math.random(0, 0xFFFF), math.random(0, 0xFFFF))

    local tOut        = {}
    local nOutIdx     = 0
    local nLen        = #sCode
    local nPos        = 1
    local nInjections = 0

    local function isIdChar(c)
        if not c or c == "" then return false end
        local b = c:byte()
        return (b >= 65 and b <= 90)
            or (b >= 97 and b <= 122)
            or (b >= 48 and b <= 57)
            or b == 95
    end

    local function emit(s)
        nOutIdx = nOutIdx + 1
        tOut[nOutIdx] = s
    end

    while nPos <= nLen do
        local c = sCode:sub(nPos, nPos)

        -- ============ STRING LITERALS ============
        if c == '"' or c == "'" then
            local q      = c
            local nStart = nPos
            nPos = nPos + 1
            while nPos <= nLen do
                local c2 = sCode:sub(nPos, nPos)
                if c2 == '\\' then nPos = nPos + 2
                elseif c2 == q then nPos = nPos + 1; break
                else nPos = nPos + 1 end
            end
            emit(sCode:sub(nStart, nPos - 1))

        -- ============ COMMENTS ============
        elseif c == '-' and nPos + 1 <= nLen
                        and sCode:sub(nPos + 1, nPos + 1) == '-' then
            local nComStart = nPos
            nPos = nPos + 2
            local bLong = false
            if nPos <= nLen and sCode:sub(nPos, nPos) == '[' then
                local nEq    = 0
                local nProbe = nPos + 1
                while nProbe <= nLen and sCode:sub(nProbe, nProbe) == '=' do
                    nEq = nEq + 1; nProbe = nProbe + 1
                end
                if nProbe <= nLen and sCode:sub(nProbe, nProbe) == '[' then
                    bLong = true
                    local sClose = ']' .. string.rep('=', nEq) .. ']'
                    local nEnd   = sCode:find(sClose, nProbe + 1, true)
                    nPos = nEnd and (nEnd + #sClose) or (nLen + 1)
                end
            end
            if not bLong then
                local nEol = sCode:find('\n', nPos)
                nPos = nEol and (nEol + 1) or (nLen + 1)
            end
            emit(sCode:sub(nComStart, nPos - 1))

        -- ============ LONG STRINGS ============
        elseif c == '[' then
            local nEq    = 0
            local nProbe = nPos + 1
            while nProbe <= nLen and sCode:sub(nProbe, nProbe) == '=' do
                nEq = nEq + 1; nProbe = nProbe + 1
            end
            if nProbe <= nLen and sCode:sub(nProbe, nProbe) == '[' then
                local sClose = ']' .. string.rep('=', nEq) .. ']'
                local nEnd   = sCode:find(sClose, nProbe + 1, true)
                if nEnd then
                    emit(sCode:sub(nPos, nEnd + #sClose - 1))
                    nPos = nEnd + #sClose
                else
                    emit(sCode:sub(nPos)); nPos = nLen + 1
                end
            else
                emit(c); nPos = nPos + 1
            end

        -- ============ KEYWORDS ============
        else
            local bInjected = false
            local cPrev = (nPos > 1) and sCode:sub(nPos - 1, nPos - 1) or ""

            if not isIdChar(cPrev) then

                -- === "goto" — inject BEFORE the goto keyword ===
                -- This catches goto-loops without breaking
                -- Lua's "label is last in block" scope rule.
                if nPos + 3 <= nLen
                   and sCode:sub(nPos, nPos + 3) == "goto"
                   and not isIdChar(sCode:sub(nPos + 4, nPos + 4) or "") then
                    emit(sCheckName .. "();")
                    nInjections = nInjections + 1
                    emit("goto")
                    nPos = nPos + 4
                    bInjected = true
                end

                -- === "function(" — inject at function entry ===
                if not bInjected
                   and nPos + 7 <= nLen
                   and sCode:sub(nPos, nPos + 7) == "function"
                   and not isIdChar(sCode:sub(nPos + 8, nPos + 8) or "") then
                    emit("function")
                    nPos = nPos + 8
                    -- Skip to closing ) of parameter list
                    local nParen = 0
                    local bFoundOpen = false
                    while nPos <= nLen do
                        local ch = sCode:sub(nPos, nPos)
                        emit(ch); nPos = nPos + 1
                        if ch == '(' then
                            nParen = nParen + 1; bFoundOpen = true
                        elseif ch == ')' then
                            nParen = nParen - 1
                            if nParen <= 0 and bFoundOpen then break end
                        end
                    end
                    -- Skip whitespace after )
                    while nPos <= nLen do
                        local cW = sCode:sub(nPos, nPos)
                        if cW == ' ' or cW == '\t'
                           or cW == '\n' or cW == '\r' then
                            emit(cW); nPos = nPos + 1
                        else break end
                    end
                    emit(sCheckName .. "();")
                    nInjections = nInjections + 1
                    bInjected = true
                end

                -- === do / then / repeat / else ===
                if not bInjected then
                    for _, sKw in ipairs({"repeat", "then", "else", "do"}) do
                        local nKwLen = #sKw
                        if nPos + nKwLen - 1 <= nLen
                           and sCode:sub(nPos, nPos + nKwLen - 1) == sKw then
                            local cAfter = (nPos + nKwLen <= nLen)
                                and sCode:sub(nPos + nKwLen, nPos + nKwLen)
                                or ""
                            if not isIdChar(cAfter) then
                                -- Guard: "else" before "if" = elseif
                                if sKw == "else" then
                                    local sLook = sCode:sub(nPos + nKwLen)
                                    if sLook:match("^%s*if[^%w_]")
                                    or sLook:match("^%s*if$") then
                                        goto skip_keyword
                                    end
                                end
                                emit(sKw); nPos = nPos + nKwLen
                                -- Preserve whitespace
                                while nPos <= nLen do
                                    local cW = sCode:sub(nPos, nPos)
                                    if cW == ' ' or cW == '\t'
                                    or cW == '\n' or cW == '\r' then
                                        emit(cW); nPos = nPos + 1
                                    else break end
                                end
                                emit(sCheckName .. "();")
                                nInjections = nInjections + 1
                                bInjected = true
                                break
                            end
                        end
                        ::skip_keyword::
                    end
                end
            end

            if not bInjected then
                emit(c); nPos = nPos + 1
            end
        end
    end

    oPreempt.nTotalInstrumented = oPreempt.nTotalInstrumented + 1
    oPreempt.nTotalInjections   = oPreempt.nTotalInjections + nInjections

    if nInjections == 0 then
        return sCode, 0
    end

    local sPrefix = "local " .. sCheckName .. "=__pc;"
    return sPrefix .. table.concat(tOut), nInjections
end

-- =============================================
-- HELPERS
-- =============================================

function oPreempt.getStats()
    return {
        nTotalInstrumented = oPreempt.nTotalInstrumented,
        nTotalInjections   = oPreempt.nTotalInjections,
        nQuantumMs         = oPreempt.DEFAULT_QUANTUM * 1000,
        nCheckInterval     = oPreempt.CHECK_INTERVAL,
    }
end

return oPreempt