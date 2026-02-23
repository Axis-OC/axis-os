--
-- /system/apps/terminal.lua
-- AxisOS Windowed Terminal
--

local oWm  = require("wm")
local fs   = require("filesystem")
local oSys = require("syscall")

local sUser = env.USER or "user"
local sHost = env.HOSTNAME or "box"
local sPwd  = env.PWD or env.HOME or "/"
local sPath = env.PATH or "/usr/commands"

local W_CW, W_CH = 60, 18
local hWin = oWm.createWindow(sUser .. "@" .. sHost .. " — Terminal",
    W_CW, W_CH, { nX = 3, nY = 2, nZ = 200 })
if not hWin then return end

-- ── State ──

local tLines    = {}
local nScrollY  = 0
local sBuf      = ""
local nMaxLines = 200
local C_FG      = 0xCCCCDD
local C_BG      = 0x0C0C1E
local C_PROMPT  = 0x55FF55
local C_ERR     = 0xFF5555
local C_CMD     = 0x55FFFF
local bRunning  = true

local function addLine(s, fg)
    tLines[#tLines + 1] = { text = s or "", fg = fg or C_FG }
    while #tLines > nMaxLines do table.remove(tLines, 1) end
    nScrollY = math.max(0, #tLines - W_CH)
end

local function render()
    oWm.clear(hWin)
    local nStart = nScrollY + 1
    for row = 1, W_CH do
        local idx = nStart + row - 1
        local tL = tLines[idx]
        if tL then
            local s = tL.text
            if #s > W_CW then s = s:sub(1, W_CW) end
            oWm.set(hWin, 1, row, s, tL.fg)
        end
    end
    -- Prompt line at bottom
    local sPrompt = sPwd:match("[^/]+$") or sPwd
    local sDisp = sPrompt .. "> " .. sBuf .. "_"
    if #sDisp > W_CW then sDisp = sDisp:sub(-W_CW) end
    oWm.set(hWin, 1, W_CH, sDisp, C_PROMPT)
    oWm.present()
end

local function printOut(s, fg)
    if not s then return end
    for sLine in (s .. "\n"):gmatch("([^\n]*)\n") do
        addLine(sLine, fg)
    end
end

-- ── Command resolution ──

local function findCmd(cmd)
    for sDir in sPath:gmatch("[^:]+") do
        local sF = sDir .. "/" .. cmd .. ".lua"
        local h = fs.open(sF, "r")
        if h then fs.close(h); return sF end
    end
    return nil
end

-- ── Built-in commands ──

local tBuiltins = {}

function tBuiltins.cd(args)
    local d = args[1] or env.HOME or "/"
    if d == ".." then
        sPwd = sPwd:match("(.*/)[^/]+/?$") or "/"
        if #sPwd > 1 and sPwd:sub(-1) == "/" then sPwd = sPwd:sub(1,-2) end
    elseif d:sub(1,1) == "/" then sPwd = d
    else sPwd = sPwd .. (sPwd == "/" and "" or "/") .. d end
end

function tBuiltins.pwd() printOut(sPwd) end
function tBuiltins.clear() tLines = {}; nScrollY = 0 end
function tBuiltins.exit() bRunning = false end

function tBuiltins.ls(args)
    local sDir = args[1] or sPwd
    if sDir:sub(1,1) ~= "/" then sDir = sPwd .. "/" .. sDir end
    local tList = fs.list(sDir)
    if tList then
        for _, s in ipairs(tList) do printOut("  " .. s) end
    else printOut("ls: cannot access " .. sDir, C_ERR) end
end

function tBuiltins.cat(args)
    if not args[1] then printOut("cat: missing file", C_ERR); return end
    local sP = args[1]
    if sP:sub(1,1) ~= "/" then sP = sPwd .. "/" .. sP end
    local h = fs.open(sP, "r")
    if h then
        local d = fs.read(h, math.huge)
        fs.close(h)
        if d then printOut(d) end
    else printOut("cat: " .. sP .. ": not found", C_ERR) end
end

-- ── Execute external command ──

local function execCmd(sCmd, tArgs)
    local sExecPath = findCmd(sCmd)
    if not sExecPath then
        printOut("sh: " .. sCmd .. ": not found", C_ERR)
        return
    end

    -- Spawn external command
    local nPid = oSys.spawn(sExecPath, 3, {
        ARGS     = tArgs,
        PWD      = sPwd,
        PATH     = sPath,
        USER     = sUser,
        HOME     = env.HOME or "/",
        HOSTNAME = sHost,
    })
    if nPid then
        oSys.wait(nPid)
        printOut("(process " .. nPid .. " exited)")
    else
        printOut("sh: failed to spawn " .. sCmd, C_ERR)
    end
end

-- ── Parse and run ──

local function parseLine(sLine)
    local tA = {}
    for w in sLine:gmatch("%S+") do tA[#tA + 1] = w end
    return tA
end

local function runCommand(sLine)
    sLine = sLine:match("^%s*(.-)%s*$") or ""
    if #sLine == 0 then return end
    addLine(sPwd .. "> " .. sLine, C_CMD)

    local tA = parseLine(sLine)
    if #tA == 0 then return end

    local cmd = tA[1]
    local args = {}
    for i = 2, #tA do args[#args + 1] = tA[i] end

    if tBuiltins[cmd] then
        tBuiltins[cmd](args)
    else
        execCmd(cmd, args)
    end
end

-- ── Welcome ──

addLine("AxisOS Terminal", C_CMD)
addLine("Type 'help' for commands, 'exit' to close.", 0x555577)
addLine("")

tBuiltins.help = function()
    printOut("Built-in: cd, ls, cat, pwd, clear, exit, help")
    printOut("External: " .. sPath)
end

render()

-- ── Main loop ──

while bRunning do
    local evt = oWm.pollEvent(hWin)
    if evt then
        if evt.sType == "close_requested" then
            bRunning = false
        elseif evt.sType == "key_down" then
            local ch   = evt.nChar or 0
            local code = evt.nCode or 0

            if ch == 13 or code == 28 then -- Enter
                runCommand(sBuf)
                sBuf = ""
                nScrollY = math.max(0, #tLines - W_CH)
                render()
            elseif ch == 8 or code == 14 then -- Backspace
                if #sBuf > 0 then sBuf = sBuf:sub(1, -2) end
                render()
            elseif ch == 3 then -- Ctrl+C
                sBuf = ""
                addLine("^C", C_ERR)
                render()
            elseif ch >= 32 and ch < 127 then
                sBuf = sBuf .. string.char(ch)
                render()
            elseif code == 200 then -- Up: scroll up
                nScrollY = math.max(0, nScrollY - 1)
                render()
            elseif code == 208 then -- Down: scroll down
                nScrollY = math.min(math.max(0, #tLines - W_CH), nScrollY + 1)
                render()
            end
        elseif evt.sType == "scroll" then
            local nDir = evt.nDir or 0
            if nDir > 0 then
                nScrollY = math.max(0, nScrollY - 3)
            else
                nScrollY = math.min(math.max(0, #tLines - W_CH), nScrollY + 3)
            end
            render()
        end
    else
        syscall("process_yield")
    end
end

oWm.destroyWindow(hWin)