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

local function getPrompt()
  return "\n" .. getPromptString()
end

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

  if #tMatches == 0 then
    -- No matches — restore buffer silently and continue
    local bOk = oFs.deviceControl(hStdin, "set_buffer", {sCurrentBuffer})
    if not bOk then
      -- deviceControl failed — write buffer back manually
      -- TTY buffer is empty after Tab, so just re-display
      oFs.write(hStdout, sCurrentBuffer)
      oFs.flush(hStdout)
    end

  elseif #tMatches == 1 then
    local sCompletion = tMatches[1]
    local sToAdd = sCompletion:sub(#sLastWord + 1)
    if bIsCommand and sToAdd:sub(-1) ~= "/" then sToAdd = sToAdd .. " " end
    local sNewBuffer = sCurrentBuffer .. sToAdd
    oFs.write(hStdout, sToAdd)
    oFs.flush(hStdout)
    local bOk = oFs.deviceControl(hStdin, "set_buffer", {sNewBuffer})
    if not bOk then
      -- Fallback: erase and redraw
      oFs.write(hStdout, "\n" .. getPromptString() .. sNewBuffer)
      oFs.flush(hStdout)
    end

  else
    -- Multiple matches
    oFs.write(hStdout, "\n")
    for _, s in ipairs(tMatches) do
      oFs.write(hStdout, "\27[32m" .. s .. "\27[37m  ")
    end

    local sCommon = findCommonPrefix(tMatches)
    local sToAdd = ""
    if #sCommon > #sLastWord then
      sToAdd = sCommon:sub(#sLastWord + 1)
    end

    local sNewBuffer = sCurrentBuffer .. sToAdd
    -- Always redraw prompt on new line after showing matches
    oFs.write(hStdout, "\n" .. getPromptString() .. sNewBuffer)
    oFs.flush(hStdout)
    local bOk = oFs.deviceControl(hStdin, "set_buffer", {sNewBuffer})
    if not bOk then
      -- deviceControl unsupported — buffer won't match screen
      -- but we continue anyway, user can retype
    end
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

-- =============================================
-- MAIN LOOP
-- =============================================

while true do
  oFs.write(hStdout, getPrompt())
  oFs.flush(hStdout)

  local line = readLine()
  if not line then break end

  -- Trim
  local sLine = line
  -- remove leading/trailing whitespace
  sLine = sLine:match("^%s*(.-)%s*$") or ""

  if #sLine > 0 then
    -- Add to history (skip duplicates of last entry)
    if #tHistory == 0 or tHistory[#tHistory] ~= sLine then
      table.insert(tHistory, sLine)
      -- Cap history at 100 entries
      if #tHistory > 100 then table.remove(tHistory, 1) end
    end

    local args = parseLine(sLine)
    if #args > 0 then
      local cmd = args[1]
      table.remove(args, 1)

      if builtins[cmd] then
        if not builtins[cmd](args) then break end
      else
        local execPath = findExecutable(cmd)
        if execPath then
          local ring = syscall("process_get_ring")
          local pid, err = syscall("process_spawn", execPath, ring, {
            ARGS = args,
            PWD = ENV.PWD,
            PATH = ENV.PATH,
            USER = ENV.USER,
            HOME = ENV.HOME,
            HOSTNAME = ENV.HOSTNAME,
          })
          if pid then
            syscall("process_wait", pid)
          else
            oFs.write(hStderr, "sh: " .. tostring(err) .. "\n")
          end
        else
          oFs.write(hStderr, "sh: " .. cmd .. ": command not found\n")
        end
      end
    end
  end
end

oFs.close(hStdin)
oFs.close(hStdout)