--
-- /bin/sh.lua
-- AxisOS Shell v2
-- Tab completion, command history, proper line editing.
--

local oFs = require("filesystem")
local oSys = require("syscall")

local hStdin = oFs.open("/dev/tty", "r")
local hStdout = oFs.open("/dev/tty", "w")
local hStderr = hStdout

if not hStdin then syscall("kernel_panic", "SH: No TTY") end

local ENV = env or {}
ENV.PWD = ENV.PWD or "/"
ENV.PATH = ENV.PATH or "/usr/commands"
ENV.USER = ENV.USER or "user"
ENV.HOME = ENV.HOME or "/"
ENV.HOSTNAME = ENV.HOSTNAME or "box"

-- =============================================
-- PARSING
-- =============================================

local function parseLine(line)
  local args = {}
  local current = ""
  local inQuote = false
  for i = 1, #line do
    local c = line:sub(i,i)
    if c == '"' then
      inQuote = not inQuote
    elseif c == ' ' and not inQuote then
      if #current > 0 then table.insert(args, current); current = "" end
    elseif c ~= "\n" then
      current = current .. c
    end
  end
  if #current > 0 then table.insert(args, current) end
  return args
end

-- =============================================
-- PROMPT
-- =============================================

local function getPromptString()
  local r = syscall("process_get_ring")
  local char = (r == 2.5) and "#" or "$"
  local path = ENV.PWD
  if ENV.HOME and #ENV.HOME > 0 and path:sub(1, #ENV.HOME) == ENV.HOME then
    path = "~" .. path:sub(#ENV.HOME + 1)
  end
  return string.format("\27[32m%s@%s\27[37m:\27[34m%s\27[37m%s ", ENV.USER, ENV.HOSTNAME, path, char)
end

-- local function getPrompt()
--  return "\n" .. getPromptString()
-- end

-- =============================================
-- COMMAND RESOLUTION
-- =============================================

local function findExecutable(cmd)
  if cmd:sub(1,1) == "/" or cmd:sub(1,2) == "./" then
    local path = cmd
    if path:sub(1,2) == "./" then path = ENV.PWD .. path:sub(2) end
    return path
  end
  for path in string.gmatch(ENV.PATH, "[^:]+") do
    local full = path .. "/" .. cmd .. ".lua"
    local h = oFs.open(full, "r")
    if h then
      oFs.close(h)
      return full
    end
  end
  return nil
end

-- =============================================
-- BUILTINS
-- =============================================

local builtins = {}

function builtins.cd(args)
  local newDir = args[1] or ENV.HOME
  if newDir == ".." then
    ENV.PWD = ENV.PWD:match("(.*/)[^/]+/?$") or "/"
    if ENV.PWD:sub(#ENV.PWD) == "/" and #ENV.PWD > 1 then
      ENV.PWD = ENV.PWD:sub(1, -2)
    end
    return true
  end
  if newDir:sub(1,1) ~= "/" then
    newDir = ENV.PWD .. (ENV.PWD == "/" and "" or "/") .. newDir
  end
  local list = oFs.list(newDir)
  if list then
    ENV.PWD = newDir
  else
    oFs.write(hStderr, "cd: " .. newDir .. ": No such directory\n")
  end
  return true
end

function builtins.exit() return false end

function builtins.pwd()
  oFs.write(hStdout, ENV.PWD .. "\n")
  return true
end

function builtins.export(args)
  if args[1] then
    local k, v = args[1]:match("([^=]+)=(.*)")
    if k then ENV[k] = v end
  end
  return true
end

function builtins.history()
  -- defined below after tHistory is declared
  return true
end

-- =============================================
-- TAB COMPLETION (regex-free)
-- =============================================

local function startsWith(s, prefix)
  if #prefix == 0 then return true end
  return s:sub(1, #prefix) == prefix
end

local function findCommonPrefix(tStrings)
  if #tStrings == 0 then return "" end
  if #tStrings == 1 then return tStrings[1] end
  local sFirst = tStrings[1]
  local nLen = #sFirst
  for i = 2, #tStrings do
    local s = tStrings[i]
    local nMinLen = math.min(nLen, #s)
    nLen = nMinLen
    for j = 1, nMinLen do
      if sFirst:sub(j, j) ~= s:sub(j, j) then
        nLen = j - 1
        break
      end
    end
  end
  return sFirst:sub(1, nLen)
end

local function getCompletions(sPartial, bIsCommand)
  local tMatches = {}

  if bIsCommand then
    -- Search PATH directories
    for sDir in string.gmatch(ENV.PATH, "[^:]+") do
      local tList = oFs.list(sDir)
      if tList and type(tList) == "table" then
        for _, sName in ipairs(tList) do
          local sClean = sName
          if sClean:sub(-1) == "/" then sClean = sClean:sub(1, -2) end
          -- Strip .lua extension for command names
          local sCmd = sClean
          if sCmd:sub(-4) == ".lua" then sCmd = sCmd:sub(1, -5) end
          if startsWith(sCmd, sPartial) then
            table.insert(tMatches, sCmd)
          end
        end
      end
    end
    -- Also search builtins
    for sName, _ in pairs(builtins) do
      if startsWith(sName, sPartial) then
        table.insert(tMatches, sName)
      end
    end
  else
    -- File/directory completion
    local sDir, sPrefix
    -- Find last / in partial
    local nLastSlash = 0
    for i = #sPartial, 1, -1 do
      if sPartial:sub(i, i) == "/" then nLastSlash = i; break end
    end

    if nLastSlash > 0 then
      sDir = sPartial:sub(1, nLastSlash)
      sPrefix = sPartial:sub(nLastSlash + 1)
    else
      sDir = ENV.PWD .. (ENV.PWD == "/" and "" or "/")
      sPrefix = sPartial
    end

    -- Resolve relative path
    if sDir:sub(1,1) ~= "/" then
      sDir = ENV.PWD .. (ENV.PWD == "/" and "" or "/") .. sDir
    end

    local tList = oFs.list(sDir)
    if tList and type(tList) == "table" then
      for _, sName in ipairs(tList) do
        local sClean = sName
        local bIsDir = (sClean:sub(-1) == "/")
        if bIsDir then sClean = sClean:sub(1, -2) end

        if startsWith(sClean, sPrefix) then
          local sEntry = sClean
          if bIsDir then sEntry = sEntry .. "/" end
          table.insert(tMatches, sEntry)
        end
      end
    end
  end

  table.sort(tMatches)
  -- Deduplicate
  local tUnique = {}
  local sPrev = nil
  for _, s in ipairs(tMatches) do
    if s ~= sPrev then
      table.insert(tUnique, s)
      sPrev = s
    end
  end
  return tUnique
end

-- =============================================
-- HISTORY
-- =============================================

local tHistory = {}
local nHistoryIdx = 0

builtins.history = function()
  for i, sLine in ipairs(tHistory) do
    oFs.write(hStdout, string.format(" %3d  %s\n", i, sLine))
  end
  return true
end

-- =============================================
-- LINE EDITOR (uses TTY cooked mode with tab/arrow signals)
-- =============================================

local function eraseLine(sText)
  -- Send backspaces to erase sText from screen
  for i = 1, #sText do
    oFs.write(hStdout, "\b")
  end
end

local function replaceLine(sOld, sNew)
  eraseLine(sOld)
  oFs.write(hStdout, sNew)
  oFs.flush(hStdout)
  oFs.deviceControl(hStdin, "set_buffer", {sNew})
end

local function handleTab(sCurrentBuffer)
  local sLastWord = ""
  local nWordStart = #sCurrentBuffer + 1
  for i = #sCurrentBuffer, 1, -1 do
    if sCurrentBuffer:sub(i, i) == " " then break end
    nWordStart = i
  end
  sLastWord = sCurrentBuffer:sub(nWordStart)

  local sBeforeWord = sCurrentBuffer:sub(1, nWordStart - 1)
  local bIsCommand = true
  for i = 1, #sBeforeWord do
    if sBeforeWord:sub(i, i) ~= " " then
      bIsCommand = false
      break
    end
  end

  local tMatches = getCompletions(sLastWord, bIsCommand)

  -- For file paths, extract just the filename prefix (after last /)
  -- Commands: sTypedPrefix == sLastWord (no slashes)
  -- Files:    "/etc/p" → sTypedPrefix = "p"
  local sTypedPrefix = sLastWord
  if not bIsCommand then
    for i = #sLastWord, 1, -1 do
      if sLastWord:sub(i, i) == "/" then
        sTypedPrefix = sLastWord:sub(i + 1)
        break
      end
    end
  end

  if #tMatches == 0 then
    -- No matches — restore buffer, no visual change
    oFs.deviceControl(hStdin, "set_buffer", {sCurrentBuffer})

  elseif #tMatches == 1 then
    local sCompletion = tMatches[1]
    local sToAdd = sCompletion:sub(#sTypedPrefix + 1)
    if bIsCommand and sToAdd:sub(-1) ~= "/" then
      sToAdd = sToAdd .. " "
    end
    local sNewBuffer = sCurrentBuffer .. sToAdd
    if #sToAdd > 0 then
      io.write(sToAdd)
    end
    oFs.deviceControl(hStdin, "set_buffer", {sNewBuffer})

  else
    -- Multiple matches
    io.write("\n")
    for _, s in ipairs(tMatches) do
      io.write("\27[32m" .. s .. "\27[37m  ")
    end

    local sCommon = findCommonPrefix(tMatches)
    local sToAdd = ""
    if #sCommon > #sTypedPrefix then
      sToAdd = sCommon:sub(#sTypedPrefix + 1)
    end

    local sNewBuffer = sCurrentBuffer .. sToAdd
    io.write("\n" .. getPromptString() .. sNewBuffer)
    oFs.deviceControl(hStdin, "set_buffer", {sNewBuffer})
  end
end

local function handleHistoryUp(sCurrentBuffer)
  if #tHistory == 0 then
    oFs.deviceControl(hStdin, "set_buffer", {sCurrentBuffer})
    return
  end
  if nHistoryIdx < #tHistory then
    nHistoryIdx = nHistoryIdx + 1
  end
  local sLine = tHistory[#tHistory - nHistoryIdx + 1]
  replaceLine(sCurrentBuffer, sLine)
end

local function handleHistoryDown(sCurrentBuffer)
  if nHistoryIdx > 1 then
    nHistoryIdx = nHistoryIdx - 1
    local sLine = tHistory[#tHistory - nHistoryIdx + 1]
    replaceLine(sCurrentBuffer, sLine)
  elseif nHistoryIdx == 1 then
    nHistoryIdx = 0
    replaceLine(sCurrentBuffer, "")
  else
    oFs.deviceControl(hStdin, "set_buffer", {sCurrentBuffer})
  end
end

local function readLine()
  local sResult = oFs.read(hStdin)
  if not sResult then return nil end

  -- Check for special prefixes from TTY
  if sResult:sub(1, 1) == "\t" then
    -- Tab pressed
    handleTab(sResult:sub(2))
    return readLine() -- recurse to continue reading

  elseif sResult:sub(1, 3) == "\27[A" then
    -- Up arrow
    handleHistoryUp(sResult:sub(4))
    return readLine()

  elseif sResult:sub(1, 3) == "\27[B" then
    -- Down arrow
    handleHistoryDown(sResult:sub(4))
    return readLine()
  end

  -- Normal line (after Enter)
  nHistoryIdx = 0
  return sResult
end


local function parseRedirects(tArgs)
    -- Returns: cleaned args, output file path, append mode
    local tClean = {}
    local sOutFile = nil
    local bAppend = false
    local i = 1
    while i <= #tArgs do
        if tArgs[i] == ">>" then
            bAppend = true
            i = i + 1
            if i <= #tArgs then sOutFile = tArgs[i] end
        elseif tArgs[i] == ">" then
            bAppend = false
            i = i + 1
            if i <= #tArgs then sOutFile = tArgs[i] end
        elseif tArgs[i]:sub(-2) == ">>" then
            -- handle "file>>" edge case? no, keep it simple
            table.insert(tClean, tArgs[i])
        elseif tArgs[i]:sub(-1) == ">" then
            -- "echo>file" without space — not supported, treat as arg
            table.insert(tClean, tArgs[i])
        else
            table.insert(tClean, tArgs[i])
        end
        i = i + 1
    end
    -- resolve output path
    if sOutFile and sOutFile:sub(1,1) ~= "/" then
        sOutFile = ENV.PWD .. (ENV.PWD == "/" and "" or "/") .. sOutFile
        sOutFile = sOutFile:gsub("//", "/")
    end
    return tClean, sOutFile, bAppend
end

local function splitPipeline(tArgs)
    -- Split argument list on "|" tokens
    local tSegments = {}
    local tCurrent = {}
    for _, sToken in ipairs(tArgs) do
        if sToken == "|" then
            if #tCurrent > 0 then
                table.insert(tSegments, tCurrent)
            end
            tCurrent = {}
        else
            table.insert(tCurrent, sToken)
        end
    end
    if #tCurrent > 0 then
        table.insert(tSegments, tCurrent)
    end
    return tSegments
end


-- =============================================
-- PIPELINE & REDIRECTION HELPERS
-- =============================================

local function executeSimpleCommand(tArgs, sOutFile, bAppend)
    if #tArgs == 0 then return true end

    local cmd = tArgs[1]
    local cmdArgs = {}
    for i = 2, #tArgs do table.insert(cmdArgs, tArgs[i]) end

    if builtins[cmd] then
        return builtins[cmd](cmdArgs)
    end

    local execPath = findExecutable(cmd)
    if not execPath then
        oFs.write(hStderr, "sh: " .. cmd .. ": command not found\n")
        return true
    end

    local ring = syscall("process_get_ring")
    local myPid = syscall("process_get_pid")

    local tChildEnv = {
        ARGS = cmdArgs,
        PWD = ENV.PWD,
        PATH = ENV.PATH,
        USER = ENV.USER,
        HOME = ENV.HOME,
        HOSTNAME = ENV.HOSTNAME,
    }

    -- === REDIRECT: save/swap/restore ===
    local hRedirectFile = nil
    local sOrigStdout = nil

    if sOutFile then
        tChildEnv.NO_COLOR = "1"  -- strip ANSI in child output
        local sMode = bAppend and "a" or "w"
        hRedirectFile = oFs.open(sOutFile, sMode)
        if not hRedirectFile then
            oFs.write(hStderr, "sh: cannot open " .. sOutFile .. " for writing\n")
            return true
        end
        sOrigStdout = syscall("ob_get_standard_handle", myPid, -11)
        syscall("ob_set_standard_handle", myPid, -11, hRedirectFile._token)
    end

    local pid, err = syscall("process_spawn", execPath, ring, tChildEnv)

    -- restore immediately so shell's own output is normal
    if sOrigStdout then
        syscall("ob_set_standard_handle", myPid, -11, sOrigStdout)
    end

    if pid then
        syscall("process_wait", pid)
    else
        oFs.write(hStderr, "sh: " .. tostring(err) .. "\n")
    end

    if hRedirectFile then
        oFs.close(hRedirectFile)
    end

    return true
end

local function executePipeline(tSegments)
    local sPrevTempPath = nil
    local myPid = syscall("process_get_pid")

    for nStage = 1, #tSegments do
        local tStageArgs = tSegments[nStage]
        if #tStageArgs == 0 then goto pipe_continue end

        local cmd = tStageArgs[1]
        local cmdArgs = {}
        for i = 2, #tStageArgs do table.insert(cmdArgs, tStageArgs[i]) end

        local sOutFile, bAppend = nil, false
        if nStage == #tSegments then
            tStageArgs, sOutFile, bAppend = parseRedirects(tStageArgs)
            cmd = tStageArgs[1]
            cmdArgs = {}
            for i = 2, #tStageArgs do table.insert(cmdArgs, tStageArgs[i]) end
        end

        if builtins[cmd] then
            builtins[cmd](cmdArgs)
            goto pipe_continue
        end

        local execPath = findExecutable(cmd)
        if not execPath then
            oFs.write(hStderr, "sh: " .. cmd .. ": command not found\n")
            return true
        end

        local ring = syscall("process_get_ring")

        local sThisTempPath = nil
        if nStage < #tSegments then
            sThisTempPath = "/tmp/.pipe_" .. tostring(nStage) .. "_" .. tostring(math.random(10000, 99999))
        end

        local tChildEnv = {
            ARGS = cmdArgs,
            PWD = ENV.PWD,
            PATH = ENV.PATH,
            USER = ENV.USER,
            HOME = ENV.HOME,
            HOSTNAME = ENV.HOSTNAME,
        }

        -- strip ANSI if output goes to a temp file or redirect
        if sThisTempPath or sOutFile then
            tChildEnv.NO_COLOR = "1"
        end

        -- === SAVE current standard handles ===
        local sOrigStdout = syscall("ob_get_standard_handle", myPid, -11)
        local sOrigStdin  = syscall("ob_get_standard_handle", myPid, -10)

        -- === SWAP stdin if reading from previous stage ===
        local hPipeIn = nil
        if sPrevTempPath then
            hPipeIn = oFs.open(sPrevTempPath, "r")
            if hPipeIn then
                syscall("ob_set_standard_handle", myPid, -10, hPipeIn._token)
            end
        end

        -- === SWAP stdout for pipe output or file redirect ===
        local hOutFile = nil
        if sThisTempPath then
            hOutFile = oFs.open(sThisTempPath, "w")
            if hOutFile then
                syscall("ob_set_standard_handle", myPid, -11, hOutFile._token)
            end
        elseif sOutFile then
            local sMode = bAppend and "a" or "w"
            hOutFile = oFs.open(sOutFile, sMode)
            if hOutFile then
                syscall("ob_set_standard_handle", myPid, -11, hOutFile._token)
            end
        end

        -- === SPAWN (child inherits swapped handles) ===
        local pid, err = syscall("process_spawn", execPath, ring, tChildEnv)

        -- === RESTORE immediately ===
        if sOrigStdout then syscall("ob_set_standard_handle", myPid, -11, sOrigStdout) end
        if sOrigStdin  then syscall("ob_set_standard_handle", myPid, -10, sOrigStdin)  end

        if pid then
            syscall("process_wait", pid)
        else
            oFs.write(hStderr, "sh: " .. tostring(err) .. "\n")
        end

        -- cleanup handles
        if hOutFile then oFs.close(hOutFile) end
        if hPipeIn  then oFs.close(hPipeIn)  end

        -- === DELETE previous stage's temp file (we finished reading it) ===
        if sPrevTempPath then
            oFs.remove(sPrevTempPath)
        end

        sPrevTempPath = sThisTempPath
        ::pipe_continue::
    end

    -- cleanup last temp (edge case: last stage had piped input)
    if sPrevTempPath then
        oFs.remove(sPrevTempPath)
    end

    return true
end

-- =============================================
-- MAIN LOOP
-- =============================================


while true do
  io.write("\n" .. getPromptString())

  local line = readLine()
  if not line then break end

  -- Ctrl+C: discard and show new prompt
  if line == "\3" then
    oFs.write(hStdout, "^C\n")
    goto main_continue
  end

  -- Trim
  local sLine = line
  sLine = sLine:match("^%s*(.-)%s*$") or ""

  if #sLine > 0 then
    -- Add to history (skip duplicates of last entry)
    if #tHistory == 0 or tHistory[#tHistory] ~= sLine then
      table.insert(tHistory, sLine)
      if #tHistory > 100 then table.remove(tHistory, 1) end
    end

    local args = parseLine(sLine)
    if #args > 0 then

      -- Check for pipeline
      local tSegments = splitPipeline(args)

      if #tSegments > 1 then
        -- Multi-command pipeline
        executePipeline(tSegments)

      else
        -- Single command — check for redirects
        local tCleanArgs, sOutFile, bAppend = parseRedirects(args)

        if #tCleanArgs > 0 then
          local bContinue = executeSimpleCommand(tCleanArgs, sOutFile, bAppend)
          if not bContinue then break end
        end
      end

    end
  end

  ::main_continue::
end

oFs.close(hStdin)
oFs.close(hStdout)