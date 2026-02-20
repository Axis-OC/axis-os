--
-- /lib/hbm/rbmk.lua
-- High-Level RBMK Reactor Control Library for AxisOS
--
-- Wraps the hbm_rbmk KCMD driver into an ergonomic OOP API.
-- Users never touch device files or IPC directly.
--
-- Usage:
--   local rbmk = require("hbm.rbmk")
--   local reactor = rbmk.open()
--   reactor:az5()
--   for col in reactor:eachFuel() do print(col.enrichment) end
--   reactor:close()
--
--[[
rbmk.open([addr])         → Reactor      Connect to console
rbmk.crane([addr])        → Crane        Connect to crane
rbmk.fuelRod([addr])      → FuelRod      Direct fuel rod access
rbmk.controlRod([addr])   → ControlRod   Direct control rod access
rbmk.boiler([addr])       → Boiler       Direct boiler access
rbmk.heater([addr])       → Heater       Direct heater access
rbmk.cooler([addr])       → Cooler       Direct cooler access
rbmk.outgasser([addr])    → Outgasser    Direct outgasser access
rbmk.scan()               → number       Rescan all components
rbmk.list([type])         → table        List discovered components

Reactor (console-based):
  :az5()                                  Emergency shutdown
  :setLevel(0..1)                         All control rods
  :setColumnLevel(gx, gy, 0..1)          Specific rod
  :setColorLevel("RED"|0..4, 0..1)       By color group
  :setColor(gx, gy, "RED"|0..4)          Assign color
  :column(gx, gy)          → table       Query single column
  :grid()                  → table       Full 15×15 scan
  :pos()                   → table       Reactor center coords
  :stats()                 → table       Aggregate statistics
  :eachColumn()            → iterator    All columns
  :eachFuel()              → iterator    Fuel columns only
  :eachControl()           → iterator    Control columns only
  :eachBoiler()            → iterator    Boiler columns only
  :eachType(type)          → iterator    Columns of given type

Crane:
  :move("up"|"down"|"left"|"right")       Single step
  :moveTo(stepsF, stepsL)                 Multi-step convenience
  :load()                                 Lower crane to load/unload
  :pos()                   → x, z        Current position
  :depletion()             → number       Held rod enrichment
  :xenon()                 → number       Held rod xenon

FuelRod:
  :info()                  → table       All data in one call
  :heat() :flux() :fluxRatio()           Individual queries
  :enrichment() :xenon()
  :coreHeat() :skinHeat()
  :rodType() :moderated() :coords()

ControlRod:
  :info()                  → table       All data in one call
  :heat() :level() :targetLevel()        Individual queries
  :setLevel(0..100)                      Set extraction %
  :coords()

Boiler:
  :info()                  → table       All data in one call
  :heat() :steam() :steamMax()           Individual queries
  :water() :waterMax() :steamType()
  :setSteamType(1..4)                    Change compression
  :coords()

Heater / Cooler / Outgasser:
  :info()                  → table       All data in one call
  (+ type-specific individual queries)
]]

local fs = require("filesystem")

local rbmk = {}

-- Color name → integer mapping (matches RBMKColor enum)
rbmk.COLOR = {
    RED    = 0,
    YELLOW = 1,
    GREEN  = 2,
    BLUE   = 3,
    PURPLE = 4,
}

-- Column type names (matches ColumnType enum)
rbmk.TYPE = {
    BLANK        = "BLANK",
    FUEL         = "FUEL",
    FUEL_SIM     = "FUEL_SIM",
    CONTROL      = "CONTROL",
    CONTROL_AUTO = "CONTROL_AUTO",
    BOILER       = "BOILER",
    MODERATOR    = "MODERATOR",
    ABSORBER     = "ABSORBER",
    REFLECTOR    = "REFLECTOR",
    OUTGASSER    = "OUTGASSER",
    BREEDER      = "BREEDER",
    STORAGE      = "STORAGE",
    COOLER       = "COOLER",
    HEATEX       = "HEATEX",
    BURNER       = "BURNER",
}

-- Steam type mapping
rbmk.STEAM = {
    STEAM          = 1,
    HOTSTEAM       = 2,
    SUPERHOTSTEAM  = 3,
    ULTRAHOTSTEAM  = 4,
}

-- =============================================
-- INTERNAL: Device handle management
-- =============================================

local g_hDev = nil

local function ensureDev()
    if g_hDev then return g_hDev end
    g_hDev = fs.open("/dev/hbm_rbmk", "r")
    if not g_hDev then
        error("hbm_rbmk driver not loaded (is /sys/drivers/hbm_rbmk.sys.lua installed?)")
    end
    return g_hDev
end

local function ctl(sMethod, tArgs)
    local h = ensureDev()
    local bOk, vResult = fs.deviceControl(h, sMethod, tArgs or {})
    if not bOk then return nil end
    return vResult
end

-- =============================================
-- DISCOVERY
-- =============================================

function rbmk.scan()
    return ctl("scan") or 0
end

function rbmk.list(sType)
    if sType then
        return ctl("list_type", {sType}) or {}
    end
    return ctl("list") or {}
end

function rbmk.first(sType)
    return ctl("first", {sType})
end

-- =============================================
-- REACTOR HANDLE (console-based)
-- =============================================

local _R = {}
_R.__index = _R

function rbmk.open(sConsoleAddr)
    local h = ensureDev()
    sConsoleAddr = sConsoleAddr or rbmk.first("rbmk_console")
    if not sConsoleAddr then
        return nil, "no RBMK console found"
    end
    return setmetatable({
        _addr = sConsoleAddr,
        _gridCache = nil,
        _gridAge = 0,
    }, _R)
end

function _R:close()
    -- Reactor handle doesn't own the device; just clear references.
    self._addr = nil
    self._gridCache = nil
end

function _R:address()
    return self._addr
end

-- ── Reactor Position ───────────────────────

function _R:pos()
    return ctl("console_pos", {self._addr})
end

-- ── Emergency Shutdown ─────────────────────

function _R:az5()
    return ctl("console_az5", {self._addr})
end

-- ── Control Rod Level Setting ──────────────

function _R:setLevel(nLevel)
    return ctl("console_set_level", {nLevel, self._addr})
end

function _R:setColumnLevel(gx, gy, nLevel)
    return ctl("console_set_column_level", {gx, gy, nLevel, self._addr})
end

function _R:setColorLevel(vColor, nLevel)
    local nColor = type(vColor) == "string"
        and (rbmk.COLOR[vColor:upper()] or 0)
        or vColor
    return ctl("console_set_color_level", {nColor, nLevel, self._addr})
end

function _R:setColor(gx, gy, vColor)
    local nColor = type(vColor) == "string"
        and (rbmk.COLOR[vColor:upper()] or 0)
        or vColor
    return ctl("console_set_color", {gx, gy, nColor, self._addr})
end

-- ── Column Queries ─────────────────────────

function _R:column(gx, gy)
    return ctl("console_column", {gx, gy, self._addr})
end

function _R:grid()
    local tGrid = ctl("console_grid", {self._addr})
    self._gridCache = tGrid
    self._gridAge = os.clock and os.clock() or 0
    return tGrid or {}
end

-- ── Iterators ──────────────────────────────

function _R:eachColumn(bRefresh)
    local tGrid = (bRefresh or not self._gridCache) and self:grid() or self._gridCache
    local nIdx = 0
    return function()
        nIdx = nIdx + 1
        if nIdx <= #tGrid then
            local c = tGrid[nIdx]
            return c._gx, c._gy, c
        end
    end
end

function _R:eachType(sType, bRefresh)
    local tGrid = (bRefresh or not self._gridCache) and self:grid() or self._gridCache
    local nIdx = 0
    return function()
        while true do
            nIdx = nIdx + 1
            if nIdx > #tGrid then return nil end
            local c = tGrid[nIdx]
            if c.type == sType then return c._gx, c._gy, c end
        end
    end
end

function _R:eachFuel(bRefresh)
    local tGrid = (bRefresh or not self._gridCache) and self:grid() or self._gridCache
    local nIdx = 0
    return function()
        while true do
            nIdx = nIdx + 1
            if nIdx > #tGrid then return nil end
            local c = tGrid[nIdx]
            if c.type == "FUEL" or c.type == "FUEL_SIM" then
                return c._gx, c._gy, c
            end
        end
    end
end

function _R:eachControl(bRefresh)
    local tGrid = (bRefresh or not self._gridCache) and self:grid() or self._gridCache
    local nIdx = 0
    return function()
        while true do
            nIdx = nIdx + 1
            if nIdx > #tGrid then return nil end
            local c = tGrid[nIdx]
            if c.type == "CONTROL" or c.type == "CONTROL_AUTO" then
                return c._gx, c._gy, c
            end
        end
    end
end

function _R:eachBoiler(bRefresh)
    return self:eachType("BOILER", bRefresh)
end

-- ── Summary Statistics ─────────────────────

function _R:stats(bRefresh)
    local tGrid = (bRefresh or not self._gridCache) and self:grid() or self._gridCache
    local s = {
        nColumns  = #tGrid,
        nFuel     = 0,
        nControl  = 0,
        nBoiler   = 0,
        nMod      = 0,
        avgHeat   = 0,
        maxHeat   = 0,
        minEnrich = 1,
        maxXenon  = 0,
        avgLevel  = 0,
    }
    local nHeatSum   = 0
    local nLevelSum  = 0
    local nLevelCnt  = 0

    for _, c in ipairs(tGrid) do
        local h = c.hullTemp or 0
        nHeatSum = nHeatSum + h
        if h > s.maxHeat then s.maxHeat = h end

        if c.type == "FUEL" or c.type == "FUEL_SIM" then
            s.nFuel = s.nFuel + 1
            local e = c.enrichment or 1
            local x = c.xenon or 0
            if e < s.minEnrich then s.minEnrich = e end
            if x > s.maxXenon then s.maxXenon = x end
        elseif c.type == "CONTROL" or c.type == "CONTROL_AUTO" then
            s.nControl = s.nControl + 1
            nLevelSum = nLevelSum + (c.level or 0)
            nLevelCnt = nLevelCnt + 1
        elseif c.type == "BOILER" then
            s.nBoiler = s.nBoiler + 1
        elseif c.type == "MODERATOR" then
            s.nMod = s.nMod + 1
        end
    end

    s.avgHeat  = s.nColumns > 0 and (nHeatSum / s.nColumns) or 0
    s.avgLevel = nLevelCnt > 0 and (nLevelSum / nLevelCnt) or 0
    return s
end

-- =============================================
-- CRANE HANDLE
-- =============================================

local _C = {}
_C.__index = _C

function rbmk.crane(sAddr)
    sAddr = sAddr or rbmk.first("rbmk_crane")
    if not sAddr then return nil, "no crane found" end
    return setmetatable({_addr = sAddr}, _C)
end

function _C:move(sDir)  return ctl("crane_move", {sDir, self._addr}) end
function _C:load()      return ctl("crane_load", {self._addr}) end
function _C:pos()       return ctl("crane_pos", {self._addr}) end
function _C:depletion() return ctl("crane_depletion", {self._addr}) end
function _C:xenon()     return ctl("crane_xenon", {self._addr}) end

function _C:moveTo(nStepsF, nStepsL)
    -- Convenience: move multiple steps in a direction
    -- Positive = forward/left, negative = backward/right
    local nF = nStepsF or 0
    local nL = nStepsL or 0
    for _ = 1, math.abs(nF) do
        self:move(nF > 0 and "up" or "down")
    end
    for _ = 1, math.abs(nL) do
        self:move(nL > 0 and "left" or "right")
    end
end

-- =============================================
-- DIRECT COMPONENT HANDLES
-- =============================================

-- Generic component wrapper
local _Comp = {}
_Comp.__index = _Comp

local function makeComp(sType, sAddr)
    sAddr = sAddr or rbmk.first(sType)
    if not sAddr then return nil, "no " .. sType .. " found" end
    return setmetatable({_type = sType, _addr = sAddr}, _Comp)
end

function _Comp:invoke(sMethod, ...)
    return ctl("comp_invoke", {self._type, sMethod, self._addr, ...})
end

function _Comp:address() return self._addr end

-- ── Fuel Rod ───────────────────────────────

local _FuelRod = setmetatable({}, {__index = _Comp})
_FuelRod.__index = _FuelRod

function rbmk.fuelRod(sAddr)
    local c, err = makeComp("rbmk_fuel_rod", sAddr)
    if not c then return nil, err end
    return setmetatable(c, _FuelRod)
end

function _FuelRod:info()       return ctl("fuel_info", {self._addr}) end
function _FuelRod:heat()       return self:invoke("getHeat") end
function _FuelRod:flux()       return self:invoke("getFluxQuantity") end
function _FuelRod:fluxRatio()  return self:invoke("getFluxRatio") end
function _FuelRod:enrichment() return self:invoke("getDepletion") end
function _FuelRod:xenon()      return self:invoke("getXenonPoison") end
function _FuelRod:coreHeat()   return self:invoke("getCoreHeat") end
function _FuelRod:skinHeat()   return self:invoke("getSkinHeat") end
function _FuelRod:rodType()    return self:invoke("getType") end
function _FuelRod:moderated()  return self:invoke("getModerated") end
function _FuelRod:coords()     return self:invoke("getCoordinates") end

-- ── Control Rod ────────────────────────────

local _CtrlRod = setmetatable({}, {__index = _Comp})
_CtrlRod.__index = _CtrlRod

function rbmk.controlRod(sAddr)
    local c, err = makeComp("rbmk_control_rod", sAddr)
    if not c then return nil, err end
    return setmetatable(c, _CtrlRod)
end

function _CtrlRod:info()        return ctl("control_info", {self._addr}) end
function _CtrlRod:heat()        return self:invoke("getHeat") end
function _CtrlRod:level()       return self:invoke("getLevel") end
function _CtrlRod:targetLevel() return self:invoke("getTargetLevel") end
function _CtrlRod:setLevel(n)   return ctl("control_set_level", {n, self._addr}) end
function _CtrlRod:coords()      return self:invoke("getCoordinates") end

-- ── Boiler ─────────────────────────────────

local _Boiler = setmetatable({}, {__index = _Comp})
_Boiler.__index = _Boiler

function rbmk.boiler(sAddr)
    local c, err = makeComp("rbmk_boiler", sAddr)
    if not c then return nil, err end
    return setmetatable(c, _Boiler)
end

function _Boiler:info()            return ctl("boiler_info", {self._addr}) end
function _Boiler:heat()            return self:invoke("getHeat") end
function _Boiler:steam()           return self:invoke("getSteam") end
function _Boiler:steamMax()        return self:invoke("getSteamMax") end
function _Boiler:water()           return self:invoke("getWater") end
function _Boiler:waterMax()        return self:invoke("getWaterMax") end
function _Boiler:steamType()       return self:invoke("getSteamType") end
function _Boiler:setSteamType(n)   return ctl("boiler_set_steam_type", {n, self._addr}) end
function _Boiler:coords()          return self:invoke("getCoordinates") end

-- ── Heater ─────────────────────────────────

local _Heater = setmetatable({}, {__index = _Comp})
_Heater.__index = _Heater

function rbmk.heater(sAddr)
    local c, err = makeComp("rbmk_heater", sAddr)
    if not c then return nil, err end
    return setmetatable(c, _Heater)
end

function _Heater:info()       return ctl("heater_info", {self._addr}) end
function _Heater:heat()       return self:invoke("getHeat") end
function _Heater:coolant()    return self:invoke("getFill") end
function _Heater:coolantMax() return self:invoke("getFillMax") end
function _Heater:hot()        return self:invoke("getExport") end
function _Heater:hotMax()     return self:invoke("getExportMax") end
function _Heater:coldType()   return self:invoke("getFillType") end
function _Heater:hotType()    return self:invoke("getExportType") end
function _Heater:coords()     return self:invoke("getCoordinates") end

-- ── Cooler ─────────────────────────────────

local _Cooler = setmetatable({}, {__index = _Comp})
_Cooler.__index = _Cooler

function rbmk.cooler(sAddr)
    local c, err = makeComp("rbmk_cooler", sAddr)
    if not c then return nil, err end
    return setmetatable(c, _Cooler)
end

function _Cooler:info()    return ctl("cooler_info", {self._addr}) end
function _Cooler:heat()    return self:invoke("getHeat") end
function _Cooler:cryo()    return self:invoke("getCryo") end
function _Cooler:cryoMax() return self:invoke("getCryoMax") end
function _Cooler:coords()  return self:invoke("getCoordinates") end

-- ── Outgasser ──────────────────────────────

local _Outgasser = setmetatable({}, {__index = _Comp})
_Outgasser.__index = _Outgasser

function rbmk.outgasser(sAddr)
    local c, err = makeComp("rbmk_outgasser", sAddr)
    if not c then return nil, err end
    return setmetatable(c, _Outgasser)
end

function _Outgasser:info()     return ctl("outgasser_info", {self._addr}) end
function _Outgasser:gas()      return self:invoke("getGas") end
function _Outgasser:gasMax()   return self:invoke("getGasMax") end
function _Outgasser:gasType()  return self:invoke("getGasType") end
function _Outgasser:progress() return self:invoke("getProgress") end
function _Outgasser:crafting() return self:invoke("getCrafting") end
function _Outgasser:coords()   return self:invoke("getCoordinates") end

-- =============================================
-- MODULE CLEANUP
-- =============================================

function rbmk.closeDriver()
    if g_hDev then
        fs.close(g_hDev)
        g_hDev = nil
    end
end

return rbmk


--[[

Minimal e.g: 

local rbmk = require("hbm.rbmk")
local r = rbmk.open()
r:az5()
print("AZ-5 activated")


---

Dashboard:

local rbmk = require("hbm.rbmk")
local xe   = require("xe")

local reactor = rbmk.open()
if not reactor then print("No RBMK console found"); return end

local ctx = xe.createContext({
    theme = xe.THEMES.dark,
    extensions = {
        "XE_ui_shadow_buffering_render_batch",
        "XE_ui_diff_render_feature",
        "XE_ui_alt_screen_query",
        "XE_ui_deferred_clear",
        "XE_ui_imgui_navigation",
        "XE_ui_dirty_row_tracking",
        "XE_ui_run_length_grouping",
        "XE_ui_graph_api",
        "XE_ui_toast",
    },
})
if not ctx then print("xe: no context"); return end

local W, H = ctx.W, ctx.H
local running = true

local tHeatHistory = xe.timeSeries(120)
local tFluxHistory = xe.timeSeries(120)

-- Color map for column types
local TYPE_COLORS = {
    FUEL         = 0x55FF55,
    FUEL_SIM     = 0x55FFAA,
    CONTROL      = 0xFF5555,
    CONTROL_AUTO = 0xFFAA55,
    BOILER       = 0x5555FF,
    MODERATOR    = 0xAAAA55,
    ABSORBER     = 0x555555,
    REFLECTOR    = 0xFFFF55,
    OUTGASSER    = 0xFF55FF,
    BLANK        = 0x333333,
    STORAGE      = 0x888888,
    COOLER       = 0x55FFFF,
    HEATEX       = 0xAA55FF,
    BURNER       = 0xFF8800,
}

while running do
    ctx:beginFrame()
    ctx:clear(ctx:c("bg"))

    -- Refresh grid data
    local tGrid = reactor:grid()
    local stats = reactor:stats()

    tHeatHistory:push(stats.avgHeat)

    -- Title bar
    ctx:fill(1, 1, W, 1, " ", ctx:c("bar_fg"), ctx:c("bar_bg"))
    ctx:text(2, 1, "RBMK Reactor Monitor", ctx:c("accent"), ctx:c("bar_bg"))

    local rPos = reactor:pos()
    if rPos then
        ctx:textf(W - 30, 1, ctx:c("dim"), ctx:c("bar_bg"),
            "Core: %d,%d,%d",
            rPos.rbmkCenterX or 0, rPos.rbmkCenterY or 0, rPos.rbmkCenterZ or 0)
    end

    -- ── Left: 15x15 Grid Map ──
    ctx:text(2, 3, "Reactor Grid:", ctx:c("accent"))
    for _, col in ipairs(tGrid) do
        local gx = col._gx
        local gy = col._gy
        local sx = 2 + gx
        local sy = 4 + gy
        if sx <= W and sy <= H - 2 then
            local c = TYPE_COLORS[col.type] or 0x333333
            -- Heat intensity overlay
            local h = col.hullTemp or 0
            if h > 800 then c = 0xFF0000
            elseif h > 500 then c = 0xFF8800 end
            ctx:text(sx, sy, "\x07", c)
        end
    end

    -- Grid legend
    local lx = 19
    ctx:text(lx, 3, "Legend:", ctx:c("accent2"))
    local nLY = 4
    for name, color in pairs(TYPE_COLORS) do
        if nLY < H - 3 then
            ctx:text(lx, nLY, "\x07", color)
            ctx:text(lx + 2, nLY, name, ctx:c("dim"))
            nLY = nLY + 1
        end
    end

    -- ── Right: Statistics ──
    local rx = math.max(38, W / 2 + 2)
    ctx:text(rx, 3, "Statistics:", ctx:c("accent"))
    ctx:textf(rx, 4, ctx:c("fg"), nil, "Columns: %d", stats.nColumns)
    ctx:textf(rx, 5, ctx:c("fg"), nil, "Fuel:    %d  Control: %d",
        stats.nFuel, stats.nControl)
    ctx:textf(rx, 6, ctx:c("fg"), nil, "Boilers: %d  Moderators: %d",
        stats.nBoiler, stats.nMod)

    ctx:separator(rx, 7, 30)

    -- Heat display
    local heatColor = stats.avgHeat > 800 and 0xFF0000
                   or stats.avgHeat > 500 and 0xFFAA00
                   or 0x55FF55
    ctx:textf(rx, 8, heatColor, nil, "Avg Heat:    %.1f C", stats.avgHeat)
    ctx:textf(rx, 9, stats.maxHeat > 1000 and 0xFF0000 or ctx:c("fg"), nil,
        "Max Heat:    %.1f C", stats.maxHeat)

    -- Fuel status
    ctx:textf(rx, 10, ctx:c("fg"), nil,
        "Min Enrich:  %.1f%%", stats.minEnrich * 100)
    ctx:textf(rx, 11, stats.maxXenon > 50 and 0xFF55FF or ctx:c("fg"), nil,
        "Max Xenon:   %.1f%%", stats.maxXenon)

    -- Control rod level
    ctx:textf(rx, 12, ctx:c("fg"), nil,
        "Avg Rod Lvl: %.0f%%", stats.avgLevel)

    -- Heat graph
    ctx:text(rx, 14, "Heat History:", ctx:c("accent"))
    local gW = W - rx - 1
    if gW > 10 then
        ctx:lineGraph("heat_graph", rx, 15, gW, 5, tHeatHistory, {
            color     = 0xFF5555,
            bgColor   = 0x0A0A1A,
            gridColor = 0x1A1A3A,
            minY      = 0,
            maxY      = 1500,
            filled    = true,
            fillColor = 0x330000,
        })
    end

    -- AZ-5 button
    ctx:text(rx, 21, "Emergency:", ctx:c("accent2"))
    if ctx:button("az5", rx, 22, " AZ-5 SCRAM ",
        0xFFFFFF, 0xAA0000, 0xFFFF00, 0xFF0000) then
        reactor:az5()
        ctx:toastError("AZ-5 ACTIVATED — ALL RODS INSERTED")
    end

    -- Rod level slider buttons
    ctx:text(rx, H - 4, "All Rods:", ctx:c("accent2"))
    local tLevels = {0, 25, 50, 75, 100}
    local bx = rx
    for _, lvl in ipairs(tLevels) do
        local sBtn = string.format(" %d%% ", lvl)
        if ctx:button("lvl_" .. lvl, bx, H - 3, sBtn,
            ctx:c("btn_fg"), ctx:c("btn_bg"),
            ctx:c("btn_hfg"), ctx:c("btn_hbg")) then
            reactor:setLevel(lvl / 100)
            ctx:toastInfo("Rods → " .. lvl .. "%")
        end
        bx = bx + #sBtn + 1
    end

    -- Status bar
    ctx:fill(1, H, W, 1, " ", ctx:c("bar_fg"), ctx:c("bar_bg"))
    ctx:textf(2, H, ctx:c("dim"), ctx:c("bar_bg"),
        "Heat:%.0fC Fuel:%d Rod:%.0f%% | Q:Quit",
        stats.avgHeat, stats.nFuel, stats.avgLevel)

    -- Input
    local k = ctx:key()
    if k == "q" or k == "\3" then running = false end
    if k == "5" then reactor:az5(); ctx:toastError("AZ-5!") end

    ctx:endFrame()
end

ctx:destroy()
reactor:close()
rbmk.closeDriver()

--- Crane 

local rbmk = require("hbm.rbmk")

local crane = rbmk.crane()
if not crane then print("No crane found"); return end

local reactor = rbmk.open()
if not reactor then print("No console found"); return end

-- Find depleted fuel rods (enrichment < 5%)
print("Scanning for depleted rods...")
for gx, gy, col in reactor:eachFuel(true) do
    if col.enrichment and col.enrichment < 0.05 then
        print(string.format("  Depleted rod at (%d,%d) — %.1f%%",
            gx, gy, col.enrichment * 100))
    end
end

reactor:close()
rbmk.closeDriver()


--- 

Direct access

local rbmk = require("hbm.rbmk")
rbmk.scan()

-- Access all boilers
local addrs = rbmk.list("rbmk_boiler")
for _, addr in ipairs(addrs) do
    local b = rbmk.boiler(addr)
    local info = b:info()
    print(string.format("Boiler at %d,%d,%d: steam=%d/%d water=%d/%d",
        info.x, info.y, info.z,
        info.steam, info.steamMax,
        info.water, info.waterMax))
end

-- Access all coolers
for _, addr in ipairs(rbmk.list("rbmk_cooler")) do
    local c = rbmk.cooler(addr)
    local info = c:info()
    print(string.format("Cooler at %d,%d,%d: cryo=%d/%d heat=%.1f",
        info.x, info.y, info.z,
        info.cryo, info.cryoMax, info.heat))
end

rbmk.closeDriver()


]]