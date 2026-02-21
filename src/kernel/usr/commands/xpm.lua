--
-- /usr/commands/xpm.lua
-- xpm — Xen Package Manager for AxisOS
--
-- Syntax (Void/Arch hybrid):
--   xpm init                  Initialize local database
--   xpm config [key] [val]    View/edit configuration
--   xpm sync                  Sync package database
--   xpm install <pkg> [...]   Install package(s)
--   xpm remove <pkg> [...]    Remove package(s)
--   xpm search <term>         Search available packages
--   xpm list                  List installed packages
--   xpm info <pkg>            Show package details
--   xpm update                Re-download all installed packages
--   xpm sign <file>           Sign a package file (requires APPROVED key)
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

local DEFAULT_REPO   = "https://repo.axis-os.ru"
local DB_DIR         = "/etc/xpm"
local CONF_PATH      = DB_DIR .. "/xpm.conf"
local DB_PATH        = DB_DIR .. "/pkgdb.lua"
local INSTALLED_PATH = DB_DIR .. "/installed.lua"

-- These are set from config at load time
local REPO_URL  = DEFAULT_REPO
local INDEX_URL  = DEFAULT_REPO .. "/_sys/pkgindex.php"

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
local _buf = {}
local _bufN = 0

local function out(s)
    _bufN = _bufN + 1
    _buf[_bufN] = s
end

local function flush()
    if _bufN > 0 then
        for i = _bufN + 1, #_buf do _buf[i] = nil end
        io.write(table.concat(_buf))
        _bufN = 0
    end
end

local function arrow(s)   out(C.BLU .. ":: " .. C.R .. s .. "\n") end
local function step(s)    out(C.GRN .. "   " .. C.R .. s .. "\n") end
local function warn(s)    out(C.YLW .. ":: " .. C.R .. s .. "\n") end
local function fail(s)    out(C.RED .. ":: " .. C.R .. s .. "\n") end
local function dim(s)     out(C.GRY .. "   " .. s .. C.R .. "\n") end

local function fmtSize(n)
  if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
  if n >= 1024    then return string.format("%.1f KB", n / 1024) end
  return n .. " B"
end

-- Progress bar: flushes buffer first, then writes directly for \r updates
local function progress(nCur, nTotal, sLabel)
  flush()
  local nW = 28
  local nPct = math.floor((nCur / math.max(nTotal, 1)) * 100)
  local nFill = math.floor((nCur / math.max(nTotal, 1)) * nW)
  local sBar = string.rep("#", nFill) .. string.rep("-", nW - nFill)
  io.write(string.format("\r   [%s%s%s] %3d%%  %s",
    C.CYN, sBar, C.R, nPct, fmtSize(nCur)))
end

-- =============================================
-- FILESYSTEM HELPERS
-- =============================================

local function ensureDir()
  fs.mkdir("/etc")
  fs.mkdir(DB_DIR)
end

local function stripBom(s)
  if not s then return s end
  if s:sub(1, 3) == "\239\187\191" then return s:sub(4) end
  return s
end

-- =============================================
-- CONFIG SYSTEM
-- =============================================

local g_tConf = nil

local function loadLuaFile(sPath)
  local h = fs.open(sPath, "r")
  if not h then return nil end
  local s = fs.read(h, math.huge)
  fs.close(h)
  if not s or #s == 0 then return nil end
  s = stripBom(s)
  -- Use kernel load to parse safely
  local f = load(s, sPath, "t", {})
  if not f then return nil end
  local bOk, tResult = pcall(f)
  if bOk and type(tResult) == "table" then return tResult end
  return nil
end

local function loadConf()
  if g_tConf then return g_tConf end
  g_tConf = loadLuaFile(CONF_PATH)
  if not g_tConf then
    -- Default config (xpm not initialized)
    g_tConf = {
      repos = {{name = "axis", url = DEFAULT_REPO, siglevel = "Optional"}},
      siglevel = "Optional",
      cache_dir = "/tmp/xpm",
    }
  end
  -- Apply repo URL from config
  if g_tConf.repos and g_tConf.repos[1] and g_tConf.repos[1].url then
    REPO_URL = g_tConf.repos[1].url
  end
  INDEX_URL = REPO_URL .. "/_sys/pkgindex.php"
  return g_tConf
end

local function saveConf(tConf)
  ensureDir()
  local h = fs.open(CONF_PATH, "w")
  if not h then return false end
  fs.write(h, "-- /etc/xpm/xpm.conf\n")
  fs.write(h, "-- xpm package manager configuration\n")
  fs.write(h, "return {\n")
  fs.write(h, "  repos = {\n")
  for _, repo in ipairs(tConf.repos or {}) do
    fs.write(h, string.format('    {name="%s", url="%s", siglevel="%s"},\n',
      repo.name or "axis",
      repo.url or DEFAULT_REPO,
      repo.siglevel or "Optional"))
  end
  fs.write(h, "  },\n")
  fs.write(h, string.format('  siglevel = "%s",\n', tConf.siglevel or "Optional"))
  fs.write(h, string.format('  cache_dir = "%s",\n', tConf.cache_dir or "/tmp/xpm"))
  fs.write(h, "}\n")
  fs.close(h)
  g_tConf = tConf
  return true
end

-- =============================================
-- DATABASE
-- =============================================

local g_tDb = nil
local g_tInstalled = nil

local function saveLuaFile(sPath, tData)
  ensureDir()
  local h = fs.open(sPath, "w")
  if not h then return false end
  fs.write(h, "return {\n")
  for _, t in ipairs(tData) do
    local parts = {}
    for k, v in pairs(t) do
      if type(v) == "string" then
        table.insert(parts, k .. '="' .. v:gsub('"', '\\"') .. '"')
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
-- SIGNATURE VERIFICATION
-- =============================================

local function getSigLevel()
  local tConf = loadConf()
  return tConf.siglevel or "Optional"
end

local function verifySig(sContent, tSigData)
  -- Returns: true/false, reason string
  if not tSigData then return false, "no signature" end
  if not tSigData.hash or not tSigData.sig or not tSigData.signer then
    return false, "malformed signature"
  end

  local bOk, crypto = pcall(require, "crypto")
  if not bOk then return false, "crypto library unavailable" end

  local bInit, nTier = crypto.Init()
  if not bInit then return false, "no data card" end

  -- Verify hash matches content
  local sHash = crypto.Encode64(crypto.SHA256(sContent))
  if sHash ~= tSigData.hash then
    return false, "hash mismatch (content modified)"
  end

  -- If Tier 3, verify ECDSA signature
  if nTier >= 3 then
    -- Load approved keystore
    local tKeys = loadLuaFile("/etc/pki_keystore.lua") or {}
    local tKeyInfo = tKeys[tSigData.signer]
    if not tKeyInfo then
      return false, "signer key not in approved keystore"
    end
    local oPubKey = crypto.DeserializeKey(tKeyInfo.public_key, "ec-public")
    if not oPubKey then
      return false, "cannot deserialize signer public key"
    end
    local sSigRaw = crypto.Decode64(tSigData.sig)
    local bValid = crypto.Verify(sContent, sSigRaw, oPubKey)
    if not bValid then
      return false, "ECDSA signature INVALID"
    end
    return true, "verified (signer: " .. (tKeyInfo.username or "?") .. ")"
  end

  -- Tier < 3: hash-only verification passed
  return true, "hash verified (no ECDSA - Tier < 3)"
end

local function fetchSig(sUrl)
  -- Try to download <url>.sig
  local sSigUrl = sUrl .. ".sig"
  local resp = http.get(sSigUrl)
  if not resp or resp.code ~= 200 or not resp.body or #resp.body == 0 then
    return nil
  end
  local sBody = stripBom(resp.body)
  local f = load(sBody, "sig", "t", {})
  if not f then return nil end
  local bOk, tResult = pcall(f)
  if bOk and type(tResult) == "table" then return tResult end
  return nil
end

-- =============================================
-- NETWORK
-- =============================================

local function download(sUrl, sDest, nExpectedSize)
  flush()

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
  out("\n")
  return nRecv
end

-- =============================================
-- COMMANDS
-- =============================================

-- === INIT ===
local function cmdInit()
  arrow("Initializing xpm package manager...")

  ensureDir()

  -- Check if already initialized
  local tExisting = loadLuaFile(CONF_PATH)
  if tExisting then
    warn("xpm is already initialized.")
    dim("Config:    " .. CONF_PATH)
    dim("Database:  " .. DB_PATH)
    dim("Installed: " .. INSTALLED_PATH)
    print("")
    dim("Run 'xpm config' to view/modify settings.")
    return true
  end

  -- Create default config
  local tDefConf = {
    repos = {{name = "axis", url = DEFAULT_REPO, siglevel = "Optional"}},
    siglevel = "Optional",
    cache_dir = "/tmp/xpm",
  }
  if not saveConf(tDefConf) then
    fail("Cannot create config file at " .. CONF_PATH)
    return false
  end
  step("Created " .. CONF_PATH)

  -- Create empty installed database
  if not loadLuaFile(INSTALLED_PATH) then
    saveLuaFile(INSTALLED_PATH, {})
    step("Created " .. INSTALLED_PATH)
  end

  -- Create cache dir
  fs.mkdir("/tmp")
  fs.mkdir("/tmp/xpm")

  print("")
  arrow(C.GRN .. "xpm initialized successfully." .. C.R)
  print("")
  dim("Configuration:")
  dim("  SigLevel:  Optional  (warn on unsigned)")
  dim("  Repository: " .. DEFAULT_REPO)
  print("")
  dim("Next steps:")
  dim("  xpm sync              Sync package database")
  dim("  xpm config siglevel   Change signature policy")
  dim("  xpm search <term>     Find packages")
  dim("  xpm install <pkg>     Install packages")
  return true
end

-- === CONFIG ===
local function cmdConfig(tRest)
  local tConf = loadConf()

  -- No args: show everything
  if #tRest == 0 then
    arrow("xpm configuration (" .. CONF_PATH .. ")")
    print("")

    io.write(C.CYN .. "  Repositories:" .. C.R .. "\n")
    for i, repo in ipairs(tConf.repos or {}) do
      io.write(string.format("    [%d] %s%s%s\n", i, C.WHT, repo.name, C.R))
      dim("        URL:      " .. repo.url)
      local sRL = repo.siglevel or tConf.siglevel or "Optional"
      local sRC = sRL == "Required" and C.RED or (sRL == "Never" and C.GRY or C.YLW)
      dim("        SigLevel: " .. sRC .. sRL .. C.GRY)
    end

    print("")
    local sSL = tConf.siglevel or "Optional"
    local sSC = sSL == "Required" and C.RED or (sSL == "Never" and C.GRY or C.YLW)
    io.write(C.CYN .. "  Global SigLevel: " .. sSC .. sSL .. C.R .. "\n")
    print("")
    dim("  SigLevel values:")
    dim("    Required — refuse unsigned packages entirely")
    dim("    Optional — install unsigned, warn if sig invalid")
    dim("    Never    — skip all signature verification")
    print("")
    dim("  Set with: xpm config siglevel <Required|Optional|Never>")
    dim("  Set repo: xpm config repo <url>")
    return
  end

  local sKey = tRest[1]
  local sVal = tRest[2]

  if sKey == "siglevel" then
    if not sVal then
      step("Current SigLevel: " .. (tConf.siglevel or "Optional"))
      return
    end
    -- Normalize capitalization
    local sNorm = sVal:sub(1,1):upper() .. sVal:sub(2):lower()
    if sNorm ~= "Required" and sNorm ~= "Optional" and sNorm ~= "Never" then
      fail("Invalid SigLevel: " .. sVal)
      dim("Must be one of: Required, Optional, Never")
      return
    end
    tConf.siglevel = sNorm
    -- Also update all repos that don't have explicit override
    for _, repo in ipairs(tConf.repos or {}) do
      repo.siglevel = sNorm
    end
    saveConf(tConf)
    step("SigLevel set to: " .. C.WHT .. sNorm .. C.R)

  elseif sKey == "repo" then
    if not sVal then
      step("Current repo URL: " .. (tConf.repos[1] and tConf.repos[1].url or DEFAULT_REPO))
      return
    end
    if not sVal:match("^https?://") then
      fail("Invalid URL: " .. sVal)
      return
    end
    if tConf.repos[1] then
      tConf.repos[1].url = sVal
    else
      tConf.repos = {{name = "custom", url = sVal, siglevel = tConf.siglevel}}
    end
    saveConf(tConf)
    step("Repository URL set to: " .. C.WHT .. sVal .. C.R)

  else
    fail("Unknown config key: " .. sKey)
    dim("Available keys: siglevel, repo")
  end
end

-- === SYNC ===
local function cmdSync()
  loadConf()

  local tExisting = loadLuaFile(CONF_PATH)
  if not tExisting then
    warn("xpm not initialized. Running init first...")
    flush()
    cmdInit()
    loadConf()
  end

  arrow("Syncing package database...")
  dim(INDEX_URL)
  flush()  -- show "Syncing..." before network wait

  local resp = http.get(INDEX_URL, nil, 15)  -- 15s timeout for slow connections

  if not resp or resp.code ~= 200 or not resp.body then
    fail("Failed to fetch package index")
    if resp then
      dim("HTTP " .. (resp.code or "?") .. " " .. (resp.error or ""))
      if resp.body and #resp.body > 0 then
        warn("Response (" .. #resp.body .. " bytes): " .. resp.body:sub(1, 80))
      end
    end
    dim("URL: " .. INDEX_URL)
    dim("Check: xpm config repo")
    return false
  end

  -- ... rest unchanged

  local sBody = stripBom(resp.body)

  -- Trim leading whitespace
  sBody = sBody:gsub("^%s+", "")

  if #sBody == 0 then
    fail("Empty response from server")
    return false
  end

  -- Validate the response is Lua
  local fTest, sLoadErr = load(sBody, "pkgindex", "t", {})
  if not fTest then
    fail("Received invalid package index (not valid Lua)")
    dim("Parse error: " .. tostring(sLoadErr))
    dim("First 80 chars: " .. sBody:sub(1, 80))
    return false
  end

  local bOk, tTest = pcall(fTest)
  if not bOk then
    fail("Package index execution error")
    dim("Error: " .. tostring(tTest))
    dim("This may indicate a server-side issue.")
    return false
  end

  if type(tTest) ~= "table" then
    fail("Package index returned " .. type(tTest) .. " (expected table)")
    warn("First 80 chars: " .. sBody:sub(1, 80))    -- was dim(), now visible
    warn("Body length: " .. #sBody .. " bytes")       -- ADD this line
    return false
  end

  -- Save raw response to disk (not re-serialized — preserve server format)
  ensureDir()
  local h = fs.open(DB_PATH, "w")
  if not h then
    fail("Cannot write to " .. DB_PATH)
    return false
  end
  fs.write(h, sBody)
  fs.close(h)

  g_tDb = tTest

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

  loadConf()

  -- Auto-sync if no DB
  if not loadDb() then
    warn("No package database. Syncing...")
    if not cmdSync() then return end
  end

  local sSigLevel = getSigLevel()
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

    -- Signature verification
    if sSigLevel ~= "Never" then
      local hCheck = fs.open(sDest, "r")
      local sContent = hCheck and fs.read(hCheck, math.huge) or nil
      if hCheck then fs.close(hCheck) end

      if sContent then
        local tSigData = fetchSig(sUrl)

        if tSigData then
          local bValid, sReason = verifySig(sContent, tSigData)
          if bValid then
            step(C.GRN .. "Signature OK" .. C.R .. " (" .. sReason .. ")")
          else
            if sSigLevel == "Required" then
              fail("Signature FAILED: " .. sReason)
              fail("SigLevel=Required — refusing to install.")
              fs.remove(sDest)
              goto nextPkg
            else
              warn("Signature issue: " .. sReason)
            end
          end
        else
          -- No signature available
          if sSigLevel == "Required" then
            fail("No signature found for " .. sName)
            fail("SigLevel=Required — refusing to install unsigned package.")
            fs.remove(sDest)
            goto nextPkg
          elseif sSigLevel == "Optional" then
            dim("No signature available (SigLevel=Optional, proceeding)")
          end
        end
      end
    end

    -- Track installation
    addInstalled(tPkg)
    nInstalled = nInstalled + 1

    step(C.GRN .. "Installed " .. C.R .. sName ..
         C.GRY .. " (" .. fmtSize(nBytes) .. ")" .. C.R)

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

-- === OUTDATED ===
local function cmdOutdated()
  loadConf()
  if not loadDb() then
    warn("No database. Run: xpm sync")
    return
  end
  local tInst = loadInstalled()
  if #tInst == 0 then
    warn("No packages installed.")
    return
  end

  arrow("Checking for updates...")
  flush()

  local nOutdated = 0
  for _, tEntry in ipairs(tInst) do
    local tRemote = findPkg(tEntry.name)
    if not tRemote then
      warn(tEntry.name .. ": removed from repository")
      nOutdated = nOutdated + 1
    else
      -- Compare file size as a simple change indicator
      -- (proper versioning would need a version field in the index)
      local sPath = tEntry.path or (tEntry.dest .. tEntry.file)
      local hLocal = fs.open(sPath, "r")
      if hLocal then
        local sData = fs.read(hLocal, math.huge) or ""
        fs.close(hLocal)
        if #sData ~= tRemote.size then
          nOutdated = nOutdated + 1
          out(string.format("  %s%-16s%s  local: %s  remote: %s  %s%s%s\n",
              C.WHT, tEntry.name, C.R,
              fmtSize(#sData), fmtSize(tRemote.size),
              C.YLW, "UPDATE AVAILABLE", C.R))
        end
      else
        nOutdated = nOutdated + 1
        out(string.format("  %s%-16s%s  %sMISSING (reinstall needed)%s\n",
            C.WHT, tEntry.name, C.R, C.RED, C.R))
      end
    end
  end

  if nOutdated == 0 then
    arrow(C.GRN .. "All packages up to date." .. C.R)
  else
    out("\n")
    arrow(nOutdated .. " package(s) can be updated.")
    dim("Run: xpm update")
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

  loadConf()

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

local function cmdRemoteList(tRest)
  loadConf()

  if not loadDb() then
    warn("No package database. Syncing...")
    flush()
    if not cmdSync() then return end
  end

  local tDb = loadDb()
  if not tDb or #tDb == 0 then
    warn("Package database is empty.")
    dim("Repository may have no packages, or sync failed.")
    return
  end

  local sFilter = tRest[1]
  local sLower = sFilter and sFilter:lower() or nil

  -- Group by category
  local tGroups = {}
  local tGroupOrder = {"drivers", "modules", "multilib", "executable"}
  for _, cat in ipairs(tGroupOrder) do tGroups[cat] = {} end

  local nTotal = 0
  local nInstalled = 0

  for _, p in ipairs(tDb) do
    -- Apply filter
    if sLower then
      local bMatch = false
      if p.name:lower():find(sLower, 1, true) then bMatch = true end
      if p.desc and p.desc:lower():find(sLower, 1, true) then bMatch = true end
      if p.cat:lower():find(sLower, 1, true) then bMatch = true end
      if not bMatch then goto skipPkg end
    end

    local cat = p.cat or "executable"
    if not tGroups[cat] then tGroups[cat] = {} end
    local bInst = isInstalled(p.name)
    table.insert(tGroups[cat], {pkg = p, installed = bInst})
    nTotal = nTotal + 1
    if bInst then nInstalled = nInstalled + 1 end

    ::skipPkg::
  end

  if nTotal == 0 then
    if sFilter then
      warn("No packages matching '" .. sFilter .. "'")
    else
      warn("No packages available.")
    end
    return
  end

  -- Header
  local sFilterMsg = sFilter and (" matching '" .. C.WHT .. sFilter .. C.R .. "'") or ""
  arrow(nTotal .. " packages available" .. sFilterMsg ..
        C.GRY .. " (" .. nInstalled .. " installed)" .. C.R)
  out("\n")

  -- Render each category
  for _, cat in ipairs(tGroupOrder) do
    local tList = tGroups[cat]
    if tList and #tList > 0 then
      local sColor = CAT_COLORS[cat] or C.GRY
      local sLabel = CAT_LABELS[cat] or cat
      out(string.format("  %s%s%s (%d)\n", sColor, sLabel .. "s", C.R, #tList))

      -- Column header
      out(string.format("  %s  %-20s %8s  %s%s\n",
          C.GRY, "NAME", "SIZE", "STATUS", C.R))
      out(C.GRY .. "  " .. string.rep("-", 52) .. C.R .. "\n")

      for _, entry in ipairs(tList) do
        local p = entry.pkg
        local sName = p.name
        if #sName > 18 then sName = sName:sub(1, 15) .. "..." end

        local sStatus
        if entry.installed then
          sStatus = C.GRN .. " [installed]" .. C.R
        else
          sStatus = ""
        end

        local sDesc = ""
        if p.desc and #p.desc > 0 then
          local nMaxDesc = 30
          sDesc = p.desc
          if #sDesc > nMaxDesc then sDesc = sDesc:sub(1, nMaxDesc - 2) .. ".." end
          sDesc = C.GRY .. " " .. sDesc .. C.R
        end

        out(string.format("  %s  %s%-20s%s %8s %s%s\n",
            sColor .. "\x07" .. C.R,
            C.WHT, sName, C.R,
            fmtSize(p.size),
            sStatus,
            sDesc))
      end
      out("\n")
    end
  end

  -- Footer
  dim(string.format("  %d total, %d installed, %d available",
      nTotal, nInstalled, nTotal - nInstalled))
  out("\n")
  dim("Install with: xpm install <name>")
end

-- === INFO ===
local function cmdInfo(sName)
  if not sName then
    fail("No package specified")
    return
  end

  loadConf()

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

-- === SIGN ===
local function cmdSign(tRest)
  local sPath = tRest[1]
  if not sPath then
    fail("Usage: xpm sign <file>")
    dim("Signs a package file with your ECDSA key.")
    dim("Requires an APPROVED key in the PKI system.")
    return
  end

  -- Resolve path
  if sPath:sub(1,1) ~= "/" then
    sPath = (env.PWD or "/") .. "/" .. sPath
  end
  sPath = sPath:gsub("//", "/")

  -- Load crypto
  local bCryptoOk, crypto = pcall(require, "crypto")
  if not bCryptoOk then
    fail("crypto library not available")
    return
  end

  local bInit, nTier = crypto.Init()
  if not bInit then
    fail("No data card found")
    return
  end
  if nTier < 3 then
    fail("Tier 3 data card required for ECDSA signing (current: Tier " .. nTier .. ")")
    return
  end

  -- Load keys
  local hPriv = fs.open("/etc/signing/private.key", "r")
  if not hPriv then
    fail("No private key found at /etc/signing/private.key")
    dim("Generate keys first: sign -g")
    return
  end
  local sPrivB64 = fs.read(hPriv, math.huge)
  fs.close(hPriv)

  local hPub = fs.open("/etc/signing/public.key", "r")
  if not hPub then
    fail("No public key found at /etc/signing/public.key")
    return
  end
  local sPubB64 = fs.read(hPub, math.huge)
  fs.close(hPub)

  -- Check key is APPROVED via PKI
  arrow("Checking key approval status...")
  local bApproved = false
  local sKeyStatus = "unknown"

  local bPkiOk, oPki = pcall(require, "pki_client")
  if bPkiOk and oPki then
    if oPki.LoadConfig() then
      sKeyStatus = oPki.CheckKeyStatus(sPubB64) or "unknown"
      if sKeyStatus == "approved" then
        bApproved = true
        step("Key status: " .. C.GRN .. "APPROVED" .. C.R)
      else
        fail("Key status: " .. C.RED .. tostring(sKeyStatus):upper() .. C.R)
      end
    else
      fail("Cannot load PKI config (/etc/pki.cfg)")
      dim("Configure with: xpm config or edit /etc/pki.cfg")
    end
  else
    fail("PKI client not available")
    dim("Install pki_client: xpm install pki_client (or check /lib/pki_client.lua)")
  end

  if not bApproved then
    fail("Only APPROVED keys may sign packages.")
    dim("Key must be registered and approved by a PKI admin.")
    dim("  1. Generate key:   sign -g")
    dim("  2. Register key:   sign -r")
    dim("  3. Wait for admin approval on pki.axis-os.ru")
    return
  end

  -- Read file content
  local hFile = fs.open(sPath, "r")
  if not hFile then
    fail("Cannot read file: " .. sPath)
    return
  end
  local sContent = fs.read(hFile, math.huge)
  fs.close(hFile)

  if not sContent or #sContent == 0 then
    fail("File is empty: " .. sPath)
    return
  end

  -- Sign
  arrow("Signing " .. sPath .. "...")
  local oPrivKey = crypto.DeserializeKey(sPrivB64, "ec-private")
  if not oPrivKey then
    fail("Cannot deserialize private key")
    return
  end

  local sHash = crypto.Encode64(crypto.SHA256(sContent))
  local sSig = crypto.Sign(sContent, oPrivKey)
  if not sSig then
    fail("Signing operation failed")
    return
  end
  local sSigB64 = crypto.Encode64(sSig)
  local sFp = crypto.Encode64(crypto.SHA256(sPubB64))

  -- Write .sig file
  local sSigPath = sPath .. ".sig"
  local hSig = fs.open(sSigPath, "w")
  if not hSig then
    fail("Cannot write signature file: " .. sSigPath)
    return
  end
  fs.write(hSig, "-- xpm package signature\n")
  fs.write(hSig, "return {\n")
  fs.write(hSig, '  hash="' .. sHash .. '",\n')
  fs.write(hSig, '  signer="' .. sFp .. '",\n')
  fs.write(hSig, '  sig="' .. sSigB64 .. '",\n')
  fs.write(hSig, "}\n")
  fs.close(hSig)

  print("")
  arrow(C.GRN .. "Package signed successfully." .. C.R)
  step("File:      " .. sPath)
  step("Signature: " .. sSigPath)
  step("Hash:      " .. sHash:sub(1, 20) .. "...")
  step("Signer:    " .. sFp:sub(1, 20) .. "...")
  print("")
  dim("Upload the .sig file alongside the package on the repository.")
  dim("Signature files are hidden from the package index automatically.")
end

local function cmdClean()
  local tConf = loadConf()
  local sCache = tConf.cache_dir or "/tmp/xpm"
  local tList = fs.list(sCache)
  if not tList or #tList == 0 then
    arrow("Cache already clean.")
    return
  end
  local nRemoved = 0
  for _, sName in ipairs(tList) do
    local sClean = sName:gsub("/$", "")
    if fs.remove(sCache .. "/" .. sClean) then
      nRemoved = nRemoved + 1
    end
  end
  arrow(nRemoved .. " cached file(s) removed.")
end

-- =============================================
-- HELP
-- =============================================

local function cmdHelp()
  print("")
  print(C.CYN .. "  xpm" .. C.R .. " — Xen Package Manager for AxisOS")
  print(C.GRY .. "  " .. string.rep("-", 44) .. C.R)
  print("")
  print("  " .. C.WHT .. "Setup:" .. C.R)
  print("    xpm init              Initialize local database & config")
  print("    xpm config [key] [v]  View/edit configuration")
  print("")
  print("  " .. C.WHT .. "Commands:" .. C.R)
  print("    xpm sync              Sync package database")
  print("    xpm install <pkg>     Install package(s)")
  print("    xpm outdated            Check for updates")
  print("    xpm clean               Clear download cache")
  print("    xpm remote-list [term]  List all available packages")
  print("    -Sl [term]              remote-list (with optional filter)")
  print("    xpm remove <pkg>      Remove package(s)")
  print("    xpm search <term>     Search available packages")
  print("    xpm list              List installed packages")
  print("    xpm info <pkg>        Show package details")
  print("    xpm update            Update all installed packages")
  print("")
  print("  " .. C.WHT .. "Security:" .. C.R)
  print("    xpm sign <file>       Sign a package (requires APPROVED key)")
  print("    xpm config siglevel   Set signature policy")
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
  print("  " .. C.WHT .. "SigLevel values:" .. C.R)
  print("    Required              Refuse unsigned packages")
  print("    Optional              Warn on unsigned, install anyway")
  print("    Never                 Skip signature checks")
  print("")
  print("  " .. C.WHT .. "Examples:" .. C.R)
  print("    xpm init")
  print("    xpm config siglevel Required")
  print("    xpm install curl ping")
  print("    xpm sign /usr/commands/mypkg.lua")
  print("")
end

-- =============================================
-- ARGUMENT DISPATCH
-- =============================================

-- Load config early (sets REPO_URL, INDEX_URL)
loadConf()

if #tArgs == 0 then
  cmdHelp()
  return
end

local sCmd = tArgs[1]
local tRest = {}
for i = 2, #tArgs do table.insert(tRest, tArgs[i]) end

-- English commands
if sCmd == "init"    then cmdInit()
elseif sCmd == "config"  then cmdConfig(tRest)
elseif sCmd == "sync"    then cmdSync()
elseif sCmd == "install" or sCmd == "add"    then cmdInstall(tRest)
elseif sCmd == "outdated" or sCmd == "stale" then cmdOutdated()
elseif sCmd == "remove"  or sCmd == "rm"     then cmdRemove(tRest)
elseif sCmd == "search"  or sCmd == "find"   then cmdSearch(tRest[1])
elseif sCmd == "list"    or sCmd == "ls"     then cmdList()
elseif sCmd == "remote-list" or sCmd == "available" or sCmd == "rl" then cmdRemoteList(tRest)
elseif sCmd == "info"    or sCmd == "show"   then cmdInfo(tRest[1])
elseif sCmd == "update"  or sCmd == "upgrade"then cmdUpdate()
elseif sCmd == "sign"    then cmdSign(tRest)
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
  if sCmd:sub(1, 1) ~= "-" then
    warn("Unknown command: " .. sCmd)
    dim("Did you mean: xpm install " .. sCmd .. "?")
  else
    fail("Unknown flag: " .. sCmd)
  end
  print("")
  cmdHelp()
end

flush()