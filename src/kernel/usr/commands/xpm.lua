--
-- /usr/commands/xpm.lua
-- xpm — Xen Package Manager for AxisOS
--
-- Syntax (Void/Arch hybrid):
--   xpm sync                  Sync package database
--   xpm install <pkg> [...]   Install package(s)
--   xpm remove <pkg> [...]    Remove package(s)
--   xpm search <term>         Search available packages
--   xpm list                  List installed packages
--   xpm info <pkg>            Show package details
--   xpm update                Re-download all installed packages
--
-- Short flags:
--   xpm -Sy                   sync
--   xpm -S <pkg>              install
--   xpm -R <pkg>              remove
--   xpm -Ss <term>            search
--   xpm -Q                    list installed
--   xpm -Qi <pkg>             info
--   xpm -Syu                  sync + update all
--

local fs   = require("filesystem")
local http = require("http")
local tArgs = env.ARGS or {}

-- =============================================
-- CONFIGURATION
-- =============================================

local REPO_URL       = "https://repo.axis-os.ru"
local INDEX_URL      = REPO_URL .. "/_sys/pkgindex"
local DB_DIR         = "/etc/xpm"
local DB_PATH        = DB_DIR .. "/pkgdb.lua"
local INSTALLED_PATH = DB_DIR .. "/installed.lua"

-- =============================================
-- COLORS
-- =============================================

local C = {
  R   = "\27[37m",  BOLD = "\27[1m",
  RED = "\27[31m",  GRN  = "\27[32m",
  YLW = "\27[33m",  BLU  = "\27[34m",
  MAG = "\27[35m",  CYN  = "\27[36m",
  GRY = "\27[90m",  WHT  = "\27[37m",
}

local CAT_COLORS = {
  drivers    = C.RED,
  executable = C.GRN,
  modules    = C.CYN,
  multilib   = C.MAG,
}

local CAT_LABELS = {
  drivers    = "driver",
  executable = "command",
  modules    = "module",
  multilib   = "library",
}

-- =============================================
-- OUTPUT HELPERS
-- =============================================

local function arrow(s)   io.write(C.BLU .. ":: " .. C.R .. s .. "\n") end
local function step(s)    io.write(C.GRN .. "   " .. C.R .. s .. "\n") end
local function warn(s)    io.write(C.YLW .. ":: " .. C.R .. s .. "\n") end
local function fail(s)    io.write(C.RED .. ":: " .. C.R .. s .. "\n") end
local function dim(s)     io.write(C.GRY .. "   " .. s .. C.R .. "\n") end

local function fmtSize(n)
  if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
  if n >= 1024    then return string.format("%.1f KB", n / 1024) end
  return n .. " B"
end

local function progress(nCur, nTotal, sLabel)
  local nW = 28
  local nPct = math.floor((nCur / math.max(nTotal, 1)) * 100)
  local nFill = math.floor((nCur / math.max(nTotal, 1)) * nW)
  local sBar = string.rep("#", nFill) .. string.rep("-", nW - nFill)
  io.write(string.format("\r   [%s%s%s] %3d%%  %s",
    C.CYN, sBar, C.R, nPct, fmtSize(nCur)))
end

-- =============================================
-- DATABASE
-- =============================================

local g_tDb = nil         -- cached package index
local g_tInstalled = nil  -- installed tracking

local function ensureDir()
  fs.mkdir(DB_DIR)
end

local function loadLuaFile(sPath)
  local h = fs.open(sPath, "r")
  if not h then return nil end
  local s = fs.read(h, math.huge)
  fs.close(h)
  if not s or #s == 0 then return nil end
  local f = load(s, sPath, "t", {})
  if not f then return nil end
  local bOk, tResult = pcall(f)
  if bOk and type(tResult) == "table" then return tResult end
  return nil
end

local function saveLuaFile(sPath, tData)
  ensureDir()
  local h = fs.open(sPath, "w")
  if not h then return false end
  fs.write(h, "return {\n")
  for _, t in ipairs(tData) do
    local parts = {}
    for k, v in pairs(t) do
      if type(v) == "string" then
        table.insert(parts, k .. '="' .. v .. '"')
      elseif type(v) == "number" then
        table.insert(parts, k .. '=' .. v)
      end
    end
    fs.write(h, "  {" .. table.concat(parts, ",") .. "},\n")
  end
  fs.write(h, "}\n")
  fs.close(h)
  return true
end

local function loadDb()
  if g_tDb then return g_tDb end
  g_tDb = loadLuaFile(DB_PATH)
  return g_tDb
end

local function loadInstalled()
  if g_tInstalled then return g_tInstalled end
  g_tInstalled = loadLuaFile(INSTALLED_PATH) or {}
  return g_tInstalled
end

local function saveInstalled()
  if not g_tInstalled then return end
  saveLuaFile(INSTALLED_PATH, g_tInstalled)
end

local function findPkg(sName)
  local tDb = loadDb()
  if not tDb then return nil end
  for _, p in ipairs(tDb) do
    if p.name == sName then return p end
  end
  return nil
end

local function isInstalled(sName)
  local tInst = loadInstalled()
  for _, p in ipairs(tInst) do
    if p.name == sName then return true end
  end
  return false
end

local function addInstalled(tPkg)
  local tInst = loadInstalled()
  -- remove old entry if exists
  local tNew = {}
  for _, p in ipairs(tInst) do
    if p.name ~= tPkg.name then table.insert(tNew, p) end
  end
  table.insert(tNew, {
    name = tPkg.name,
    cat  = tPkg.cat,
    dest = tPkg.dest,
    file = tPkg.file,
    path = tPkg.dest .. tPkg.file,
  })
  g_tInstalled = tNew
  saveInstalled()
end

local function removeInstalled(sName)
  local tInst = loadInstalled()
  local tNew = {}
  for _, p in ipairs(tInst) do
    if p.name ~= sName then table.insert(tNew, p) end
  end
  g_tInstalled = tNew
  saveInstalled()
end

-- =============================================
-- NETWORK
-- =============================================

local function download(sUrl, sDest, nExpectedSize)
  local stream, sErr = http.open(sUrl)
  if not stream then return nil, sErr end

  if stream.code == 404 then
    stream:close()
    return nil, "404 Not Found"
  end

  if stream.code >= 400 then
    stream:close()
    return nil, "HTTP " .. stream.code
  end

  local hFile = fs.open(sDest, "w")
  if not hFile then
    stream:close()
    return nil, "Cannot write to " .. sDest
  end

  local nTotal = nExpectedSize or 0
  local nRecv = 0

  while true do
    local sChunk = stream:read(2048)
    if not sChunk then break end
    fs.write(hFile, sChunk)
    nRecv = nRecv + #sChunk
    if nTotal > 0 then
      progress(nRecv, nTotal)
    else
      io.write(string.format("\r   %s received...", fmtSize(nRecv)))
    end
  end

  fs.close(hFile)
  stream:close()
  io.write("\n")  -- newline after progress bar
  return nRecv
end

-- =============================================
-- COMMANDS
-- =============================================

-- === SYNC ===
local function cmdSync()
  arrow("Syncing package database...")
  dim(INDEX_URL)

  local resp = http.get(INDEX_URL)

  if not resp or resp.code ~= 200 or not resp.body then
    fail("Failed to fetch package index")
    if resp then dim("HTTP " .. (resp.code or "?") .. " " .. (resp.error or "")) end
    return false
  end

  -- Validate the response is actually Lua
  local fTest = load(resp.body, "pkgindex", "t", {})
  if not fTest then
    fail("Received invalid package index")
    return false
  end

  local bOk, tTest = pcall(fTest)
  if not bOk or type(tTest) ~= "table" then
    fail("Package index is corrupt")
    return false
  end

  -- Save to disk
  ensureDir()
  local h = fs.open(DB_PATH, "w")
  if not h then
    fail("Cannot write to " .. DB_PATH)
    return false
  end
  fs.write(h, resp.body)
  fs.close(h)

  g_tDb = tTest  -- update cache

  -- Count by category
  local tCounts = {}
  for _, p in ipairs(tTest) do
    tCounts[p.cat] = (tCounts[p.cat] or 0) + 1
  end

  local tParts = {}
  for cat, n in pairs(tCounts) do
    table.insert(tParts, n .. " " .. (CAT_LABELS[cat] or cat) .. (n > 1 and "s" or ""))
  end

  arrow(#tTest .. " packages available (" .. table.concat(tParts, ", ") .. ")")
  return true
end

-- === INSTALL ===
local function cmdInstall(tNames)
  if #tNames == 0 then
    fail("No package specified")
    print("   Usage: xpm install <package> [...]")
    return
  end

  -- Auto-sync if no DB
  if not loadDb() then
    warn("No package database. Syncing...")
    if not cmdSync() then return end
  end

  local nInstalled = 0

  for _, sName in ipairs(tNames) do
    arrow("Resolving " .. C.WHT .. sName .. C.R .. "...")

    local tPkg = findPkg(sName)
    if not tPkg then
      fail("Package not found: " .. sName)
      dim("Try: xpm search " .. sName)
      goto nextPkg
    end

    local sColor = CAT_COLORS[tPkg.cat] or C.GRY
    local sLabel = CAT_LABELS[tPkg.cat] or tPkg.cat
    local sDest  = tPkg.dest .. tPkg.file

    step(string.format("%s [%s%s%s] -> %s (%s)",
      sName, sColor, sLabel, C.R, sDest, fmtSize(tPkg.size)))

    if isInstalled(sName) then
      warn(sName .. " is already installed. Reinstalling...")
    end

    local sUrl = REPO_URL .. "/" .. tPkg.url
    arrow("Downloading...")
    dim(sUrl)

    local nBytes, sErr = download(sUrl, sDest, tPkg.size)

    if not nBytes then
      fail("Download failed: " .. tostring(sErr))
      goto nextPkg
    end

    -- Track installation
    addInstalled(tPkg)
    nInstalled = nInstalled + 1

    step(C.GRN .. "Installed " .. C.R .. sName ..
         C.GRY .. " (" .. fmtSize(nBytes) .. ")" .. C.R)

    -- Special post-install actions
    if tPkg.cat == "drivers" then
      dim("Load with: insmod " .. sDest)
    end

    ::nextPkg::
  end

  if nInstalled > 0 then
    print("")
    arrow(C.GRN .. nInstalled .. " package(s) installed." .. C.R)
  end
end

-- === REMOVE ===
local function cmdRemove(tNames)
  if #tNames == 0 then
    fail("No package specified")
    return
  end

  local tInst = loadInstalled()
  local nRemoved = 0

  for _, sName in ipairs(tNames) do
    -- Find in installed list
    local tEntry = nil
    for _, p in ipairs(tInst) do
      if p.name == sName then tEntry = p; break end
    end

    if not tEntry then
      fail(sName .. " is not installed")
      goto nextRm
    end

    arrow("Removing " .. C.WHT .. sName .. C.R .. "...")

    local sPath = tEntry.path or (tEntry.dest .. tEntry.file)
    local bOk = fs.remove(sPath)

    if bOk then
      removeInstalled(sName)
      nRemoved = nRemoved + 1
      step(sPath .. " " .. C.RED .. "deleted" .. C.R)
    else
      fail("Could not delete " .. sPath)
    end

    ::nextRm::
  end

  if nRemoved > 0 then
    arrow(nRemoved .. " package(s) removed.")
  end
end

-- === SEARCH ===
local function cmdSearch(sTerm)
  if not sTerm or #sTerm == 0 then
    fail("No search term")
    print("   Usage: xpm search <term>")
    return
  end

  if not loadDb() then
    warn("No package database. Syncing...")
    if not cmdSync() then return end
  end

  local sLower = sTerm:lower()
  local tMatches = {}

  for _, p in ipairs(g_tDb) do
    local bMatch = false
    if p.name:lower():find(sLower, 1, true) then bMatch = true end
    if p.desc and p.desc:lower():find(sLower, 1, true) then bMatch = true end
    if p.cat:lower():find(sLower, 1, true) then bMatch = true end
    if bMatch then table.insert(tMatches, p) end
  end

  if #tMatches == 0 then
    warn("No packages matching '" .. sTerm .. "'")
    return
  end

  arrow(#tMatches .. " result(s) for '" .. C.WHT .. sTerm .. C.R .. "':")
  print("")

  for _, p in ipairs(tMatches) do
    local sColor = CAT_COLORS[p.cat] or C.GRY
    local sLabel = CAT_LABELS[p.cat] or p.cat
    local sTag = isInstalled(p.name) and (C.GRN .. " [installed]" .. C.R) or ""
    local sDesc = p.desc and (C.GRY .. " " .. p.desc .. C.R) or ""

    io.write(string.format("   %s%-14s%s %s%-10s%s %6s%s%s\n",
      C.WHT, p.name, C.R,
      sColor, sLabel, C.R,
      fmtSize(p.size),
      sTag, sDesc))
  end
end

-- === LIST ===
local function cmdList()
  local tInst = loadInstalled()

  if #tInst == 0 then
    warn("No packages installed.")
    dim("Install with: xpm install <package>")
    return
  end

  arrow(#tInst .. " package(s) installed:")
  print("")

  io.write(string.format("   %s%-14s %-10s %s%s\n",
    C.GRY, "NAME", "TYPE", "PATH", C.R))
  io.write(C.GRY .. "   " .. string.rep("-", 54) .. C.R .. "\n")

  for _, p in ipairs(tInst) do
    local sColor = CAT_COLORS[p.cat] or C.GRY
    local sLabel = CAT_LABELS[p.cat] or p.cat
    local sPath  = p.path or (p.dest .. p.file)

    io.write(string.format("   %s%-14s%s %s%-10s%s %s\n",
      C.WHT, p.name, C.R,
      sColor, sLabel, C.R,
      sPath))
  end
end

-- === INFO ===
local function cmdInfo(sName)
  if not sName then
    fail("No package specified")
    return
  end

  if not loadDb() then
    warn("No database. Syncing...")
    if not cmdSync() then return end
  end

  local tPkg = findPkg(sName)

  if not tPkg then
    fail("Package not found: " .. sName)
    return
  end

  local sColor = CAT_COLORS[tPkg.cat] or C.GRY
  local sLabel = CAT_LABELS[tPkg.cat] or tPkg.cat
  local bInst  = isInstalled(sName)

  print("")
  arrow("Package: " .. C.WHT .. tPkg.name .. C.R)
  print("")
  io.write(string.format("   %-14s %s%s%s\n",    "Category:",    sColor, sLabel, C.R))
  io.write(string.format("   %-14s %s\n",         "File:",        tPkg.file))
  io.write(string.format("   %-14s %s%s\n",       "Install to:",  tPkg.dest, tPkg.file))
  io.write(string.format("   %-14s %s\n",         "Size:",        fmtSize(tPkg.size)))
  io.write(string.format("   %-14s %s\n",         "Remote URL:",  tPkg.url))

  if tPkg.sub then
    io.write(string.format("   %-14s %s\n",       "Subcategory:", tPkg.sub))
  end
  if tPkg.desc then
    io.write(string.format("   %-14s %s\n",       "Description:", tPkg.desc))
  end

  local sStatus = bInst
    and (C.GRN .. "installed" .. C.R)
    or  (C.GRY .. "not installed" .. C.R)
  io.write(string.format("   %-14s %s\n", "Status:", sStatus))
  print("")
end

-- === UPDATE ===
local function cmdUpdate()
  arrow("Syncing database...")
  if not cmdSync() then return end

  local tInst = loadInstalled()
  if #tInst == 0 then
    warn("No packages installed. Nothing to update.")
    return
  end

  arrow("Updating " .. #tInst .. " installed package(s)...")
  print("")

  local nUpdated = 0
  local nFailed  = 0

  for _, tEntry in ipairs(tInst) do
    -- Look up current info from fresh DB
    local tPkg = findPkg(tEntry.name)
    if not tPkg then
      warn(tEntry.name .. ": no longer in repository (skipped)")
      goto nextUp
    end

    local sDest = tPkg.dest .. tPkg.file
    local sUrl  = REPO_URL .. "/" .. tPkg.url

    io.write(string.format("   %s%-14s%s [%s] ",
      C.WHT, tPkg.name, C.R, CAT_LABELS[tPkg.cat] or tPkg.cat))

    local nBytes, sErr = download(sUrl, sDest, tPkg.size)

    if nBytes then
      addInstalled(tPkg)
      nUpdated = nUpdated + 1
    else
      io.write(C.RED .. " FAILED: " .. tostring(sErr) .. C.R .. "\n")
      nFailed = nFailed + 1
    end

    ::nextUp::
  end

  print("")
  arrow(string.format("%s%d updated%s, %s%d failed%s.",
    C.GRN, nUpdated, C.R,
    nFailed > 0 and C.RED or C.GRN, nFailed, C.R))
end

-- =============================================
-- HELP
-- =============================================

local function cmdHelp()
  print("")
  print(C.CYN .. "  xpm" .. C.R .. " — Xen Package Manager for AxisOS")
  print(C.GRY .. "  " .. string.rep("-", 44) .. C.R)
  print("")
  print("  " .. C.WHT .. "Commands:" .. C.R)
  print("    xpm sync              Sync package database")
  print("    xpm install <pkg>     Install package(s)")
  print("    xpm remove <pkg>      Remove package(s)")
  print("    xpm search <term>     Search available packages")
  print("    xpm list              List installed packages")
  print("    xpm info <pkg>        Show package details")
  print("    xpm update            Update all installed packages")
  print("")
  print("  " .. C.WHT .. "Short flags:" .. C.R)
  print("    -Sy                   sync")
  print("    -S <pkg>              install")
  print("    -R <pkg>              remove")
  print("    -Ss <term>            search")
  print("    -Q                    list installed")
  print("    -Qi <pkg>             info")
  print("    -Syu                  sync + update")
  print("")
  print("  " .. C.WHT .. "Examples:" .. C.R)
  print("    xpm install curl ping")
  print("    xpm search net")
  print("    xpm -S iter -Syu")
  print("")
end

-- =============================================
-- ARGUMENT DISPATCH
-- =============================================

if #tArgs == 0 then
  cmdHelp()
  return
end

local sCmd = tArgs[1]
local tRest = {}
for i = 2, #tArgs do table.insert(tRest, tArgs[i]) end

-- English commands
if sCmd == "sync"    then cmdSync()
elseif sCmd == "install" or sCmd == "add"    then cmdInstall(tRest)
elseif sCmd == "remove"  or sCmd == "rm"     then cmdRemove(tRest)
elseif sCmd == "search"  or sCmd == "find"   then cmdSearch(tRest[1])
elseif sCmd == "list"    or sCmd == "ls"     then cmdList()
elseif sCmd == "info"    or sCmd == "show"   then cmdInfo(tRest[1])
elseif sCmd == "update"  or sCmd == "upgrade"then cmdUpdate()
elseif sCmd == "help"    or sCmd == "-h"     then cmdHelp()

-- Pacman-style compound flags
elseif sCmd == "-Sy"   then cmdSync()
elseif sCmd == "-S"    then cmdInstall(tRest)
elseif sCmd == "-R"    then cmdRemove(tRest)
elseif sCmd == "-Ss"   then cmdSearch(tRest[1])
elseif sCmd == "-Q"    then cmdList()
elseif sCmd == "-Qi"   then cmdInfo(tRest[1])
elseif sCmd == "-Syu"  then cmdUpdate()

else
  -- Maybe they just typed a package name?
  if sCmd:sub(1, 1) ~= "-" then
    warn("Unknown command: " .. sCmd)
    dim("Did you mean: xpm install " .. sCmd .. "?")
  else
    fail("Unknown flag: " .. sCmd)
  end
  print("")
  cmdHelp()
end