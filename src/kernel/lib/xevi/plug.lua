--
-- /lib/xevi/plug.lua
-- xevi Plugin Manager (vim-plug style)
--
-- Plugins are Lua files stored in /etc/xevi/plug/<name>.lua
-- Each returns a table with hooks:
--
--   name            string   Plugin identifier
--   version         string   Semver
--   description     string   One-line description
--   on_load(api, opts)       Called at startup (setup keymaps, state)
--   on_key(api, buf, mode, key) → bool   Intercept keys (return true = consumed)
--   on_insert_char(api, buf, ch) → string|nil   Transform/add chars in insert mode
--   on_save(api, buf)        Called after :w
--   on_open(api, buf)        Called when buffer opens
--   on_cursor(api, buf)      Called on cursor move (throttled)
--   on_status(api, buf) → string   Extra status bar text
--   on_render(api, buf, cy, ch)    Custom rendering pass (below editor)
--   commands = {{cmd=, desc=, func=}, ...}   Extra : commands
--   colors = {}              Color overrides (merged into CLR)
--   highlights = {}          Syntax token color overrides
--   filetypes = {ext = {tabSize=4, ...}}   Per-filetype config
--

local fs   = require("filesystem")
local http = require("http")

local oPlug = {}

local PLUG_DIR  = "/etc/xevi/plug"
local STATE_FILE = "/etc/xevi/plug_state.lua"

-- =============================================
-- INTERNAL STATE
-- =============================================

local g_tDeclared  = {}   -- [name] = {url=, opts=, ...}  from config
local g_tLoaded    = {}   -- [name] = plugin return table
local g_tState     = {}   -- [name] = {installed=bool, version=, hash=, updated_at=}
local g_tErrors    = {}   -- [name] = error string

-- =============================================
-- FILESYSTEM HELPERS
-- =============================================

local function ensureDir(sPath)
    -- Create nested directories
    local sSoFar = ""
    for seg in sPath:gmatch("[^/]+") do
        sSoFar = sSoFar .. "/" .. seg
        fs.mkdir(sSoFar)
    end
end

local function fileExists(sPath)
    local h = fs.open(sPath, "r")
    if h then fs.close(h); return true end
    return false
end

local function readFile(sPath)
    local h = fs.open(sPath, "r")
    if not h then return nil end
    local tC = {}
    while true do
        local s = fs.read(h, math.huge)
        if not s then break end
        tC[#tC + 1] = s
    end
    fs.close(h)
    return table.concat(tC)
end

local function writeFile(sPath, sData)
    local h = fs.open(sPath, "w")
    if not h then return false end
    fs.write(h, sData)
    fs.close(h)
    return true
end

-- =============================================
-- STATE PERSISTENCE
-- =============================================

local function loadState()
    local s = readFile(STATE_FILE)
    if not s then g_tState = {}; return end
    local f = load(s, "plug_state", "t", {})
    if f then
        local ok, t = pcall(f)
        if ok and type(t) == "table" then g_tState = t; return end
    end
    g_tState = {}
end

local function saveState()
    ensureDir("/etc/xevi")
    local tLines = {"return {"}
    for sName, tS in pairs(g_tState) do
        tLines[#tLines + 1] = string.format(
            '  ["%s"] = {installed=%s, version="%s", updated_at="%s"},',
            sName,
            tostring(tS.installed or false),
            tS.version or "?",
            tS.updated_at or "?")
    end
    tLines[#tLines + 1] = "}"
    writeFile(STATE_FILE, table.concat(tLines, "\n") .. "\n")
end

-- =============================================
-- PLUGIN PATH HELPERS
-- =============================================

local function plugPath(sName)
    return PLUG_DIR .. "/" .. sName .. ".lua"
end

local function nameFromUrl(sUrl)
    -- Extract filename from URL: https://host/path/autopairs.lua → autopairs
    local sFile = sUrl:match("([^/]+)%.lua$") or sUrl:match("([^/]+)$")
    if sFile then return sFile:gsub("%.lua$", "") end
    return nil
end

-- =============================================
-- DECLARATION (called from config parsing)
-- =============================================

function oPlug.declare(tPlugins)
    g_tDeclared = {}
    if not tPlugins or type(tPlugins) ~= "table" then return end

    for _, tEntry in ipairs(tPlugins) do
        local sUrl  = tEntry[1] or tEntry.url
        local sName = tEntry.name or (sUrl and nameFromUrl(sUrl))
        local bLocal = tEntry["local"] or false

        if not sName then
            g_tErrors["?"] = "Plugin entry missing name and URL"
        else
            g_tDeclared[sName] = {
                url     = sUrl,
                name    = sName,
                is_local = bLocal,
                opts    = tEntry.opts or {},
                enabled = (tEntry.enabled ~= false),
            }
        end
    end
end

-- =============================================
-- DOWNLOAD / INSTALL
-- =============================================

function oPlug.install(sName, fProgress)
    local tDecl = g_tDeclared[sName]
    if not tDecl then return false, "Not declared: " .. sName end
    if not tDecl.url then return false, "No URL for: " .. sName end

    ensureDir(PLUG_DIR)

    if tDecl.is_local then
        -- Local plugin: just verify it exists
        if fileExists(tDecl.url) then
            -- Copy to plug dir
            local sCode = readFile(tDecl.url)
            if sCode then
                writeFile(plugPath(sName), sCode)
                g_tState[sName] = {
                    installed  = true,
                    version    = "local",
                    updated_at = tostring(os.clock()),
                }
                saveState()
                return true
            end
        end
        return false, "Local file not found: " .. tDecl.url
    end

    -- Remote download
    if fProgress then fProgress(sName, "downloading...") end

    local tResp = http.get(tDecl.url)
    if not tResp or tResp.code ~= 200 or not tResp.body then
        local sErr = tResp and ("HTTP " .. (tResp.code or "?")) or "Network error"
        return false, sErr
    end

    -- Validate it's actually Lua
    local fTest = load(tResp.body, "@" .. sName, "t", {})
    if not fTest then
        return false, "Invalid Lua in downloaded plugin"
    end

    writeFile(plugPath(sName), tResp.body)

    -- Extract version from plugin
    local sVersion = "?"
    pcall(function()
        local tTemp = {}
        setmetatable(tTemp, {__index = _G})
        local f2 = load(tResp.body, "@" .. sName, "t", tTemp)
        if f2 then
            local ok, tResult = pcall(f2)
            if ok and type(tResult) == "table" then
                sVersion = tResult.version or "?"
            end
        end
    end)

    g_tState[sName] = {
        installed  = true,
        version    = sVersion,
        updated_at = tostring(os.clock()),
    }
    saveState()

    if fProgress then fProgress(sName, "installed v" .. sVersion) end
    return true
end

-- =============================================
-- INSTALL ALL / UPDATE ALL
-- =============================================

function oPlug.installAll(fProgress)
    local nOk, nFail = 0, 0
    local tResults = {}

    for sName, tDecl in pairs(g_tDeclared) do
        if not tDecl.enabled then
            tResults[sName] = {ok = true, msg = "disabled"}
        elseif fileExists(plugPath(sName)) and not tDecl.is_local then
            tResults[sName] = {ok = true, msg = "already installed"}
            nOk = nOk + 1
        else
            local bOk, sErr = oPlug.install(sName, fProgress)
            tResults[sName] = {ok = bOk, msg = bOk and "installed" or sErr}
            if bOk then nOk = nOk + 1 else nFail = nFail + 1 end
        end
    end

    return nOk, nFail, tResults
end

function oPlug.updateAll(fProgress)
    local nOk, nFail = 0, 0
    local tResults = {}

    for sName, tDecl in pairs(g_tDeclared) do
        if not tDecl.enabled then
            tResults[sName] = {ok = true, msg = "disabled"}
        else
            local bOk, sErr = oPlug.install(sName, fProgress)
            tResults[sName] = {ok = bOk, msg = bOk and "updated" or sErr}
            if bOk then nOk = nOk + 1 else nFail = nFail + 1 end
        end
    end

    return nOk, nFail, tResults
end

-- =============================================
-- CLEAN (remove plugins not in config)
-- =============================================

function oPlug.clean()
    local tRemoved = {}
    local tDir = fs.list(PLUG_DIR)
    if not tDir then return tRemoved end

    for _, sFile in ipairs(tDir) do
        local sClean = sFile:gsub("/$", "")
        local sName = sClean:gsub("%.lua$", "")
        if not g_tDeclared[sName] then
            fs.remove(PLUG_DIR .. "/" .. sClean)
            g_tState[sName] = nil
            tRemoved[#tRemoved + 1] = sName
        end
    end

    if #tRemoved > 0 then saveState() end
    return tRemoved
end

-- =============================================
-- LOADING (into editor runtime)
-- =============================================

function oPlug.loadAll(tSandboxEnv, tPluginOpts)
    loadState()
    g_tLoaded = {}
    g_tErrors = {}

    for sName, tDecl in pairs(g_tDeclared) do
        if not tDecl.enabled then goto nextPlug end

        local sPath = plugPath(sName)
        local sCode = readFile(sPath)

        if not sCode then
            g_tErrors[sName] = "Not installed (run :PlugInstall)"
            goto nextPlug
        end

        -- Load plugin in a safe environment
        local tPlugEnv = {
            string = string, math = math, table = table,
            pairs = pairs, ipairs = ipairs, type = type,
            tostring = tostring, tonumber = tonumber,
            pcall = pcall, error = error, select = select,
            require = require,
        }
        setmetatable(tPlugEnv, {__index = tSandboxEnv or _G})

        local fChunk, sLoadErr = load(sCode, "@plug:" .. sName, "t", tPlugEnv)
        if not fChunk then
            g_tErrors[sName] = "Parse error: " .. tostring(sLoadErr)
            goto nextPlug
        end

        local bOk, tPlugin = pcall(fChunk)
        if not bOk then
            g_tErrors[sName] = "Init error: " .. tostring(tPlugin)
            goto nextPlug
        end

        if type(tPlugin) ~= "table" then
            g_tErrors[sName] = "Plugin must return a table"
            goto nextPlug
        end

        tPlugin._name = sName
        g_tLoaded[sName] = tPlugin

        ::nextPlug::
    end

    return g_tLoaded, g_tErrors
end

-- =============================================
-- HOOK DISPATCH
-- =============================================

-- Call a hook on all loaded plugins. Returns first non-nil result.
function oPlug.hook(sHook, ...)
    for sName, tPlug in pairs(g_tLoaded) do
        local fHook = tPlug[sHook]
        if fHook then
            local bOk, vResult = pcall(fHook, ...)
            if bOk and vResult ~= nil then
                return vResult, sName
            end
            if not bOk then
                g_tErrors[sName] = sHook .. ": " .. tostring(vResult)
            end
        end
    end
    return nil
end

-- Call a hook on all plugins, collect all results
function oPlug.hookAll(sHook, ...)
    local tResults = {}
    for sName, tPlug in pairs(g_tLoaded) do
        local fHook = tPlug[sHook]
        if fHook then
            local bOk, vResult = pcall(fHook, ...)
            if bOk and vResult ~= nil then
                tResults[#tResults + 1] = {name = sName, result = vResult}
            end
        end
    end
    return tResults
end

-- =============================================
-- QUERY
-- =============================================

function oPlug.status()
    local tStatus = {}
    for sName, tDecl in pairs(g_tDeclared) do
        local bInstalled = fileExists(plugPath(sName))
        local bLoaded = g_tLoaded[sName] ~= nil
        local sErr = g_tErrors[sName]
        local tS = g_tState[sName] or {}

        tStatus[#tStatus + 1] = {
            name      = sName,
            url       = tDecl.url,
            enabled   = tDecl.enabled,
            installed = bInstalled,
            loaded    = bLoaded,
            version   = tS.version or "?",
            updated   = tS.updated_at,
            error     = sErr,
            is_local  = tDecl.is_local,
        }
    end
    table.sort(tStatus, function(a, b) return a.name < b.name end)
    return tStatus
end

function oPlug.getLoaded()
    return g_tLoaded
end

function oPlug.getCommands()
    local tCmds = {}
    for sName, tPlug in pairs(g_tLoaded) do
        if tPlug.commands then
            for _, tCmd in ipairs(tPlug.commands) do
                tCmds[#tCmds + 1] = {
                    cmd  = tCmd.cmd,
                    desc = tCmd.desc or "",
                    func = tCmd.func,
                    plug = sName,
                }
            end
        end
    end
    return tCmds
end

function oPlug.getColors()
    local tMerged = {}
    for _, tPlug in pairs(g_tLoaded) do
        if tPlug.colors then
            for k, v in pairs(tPlug.colors) do
                tMerged[k] = v
            end
        end
    end
    return tMerged
end

function oPlug.getFiletypeConfig(sExt)
    for _, tPlug in pairs(g_tLoaded) do
        if tPlug.filetypes and tPlug.filetypes[sExt] then
            return tPlug.filetypes[sExt]
        end
    end
    return nil
end

function oPlug.getDeclared()
    return g_tDeclared
end

return oPlug