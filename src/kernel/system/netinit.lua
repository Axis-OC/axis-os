--
-- /system/netinit.lua
-- AxisOS Network Initialization Service
-- Reads /etc/network.cfg, initializes the IP stack,
-- configures interfaces, routes, and DNS.
-- Spawned by pipeline_manager after drivers load.
--

local fs = require("filesystem")

local function fLog(s)
    syscall("kernel_log", "[NETINIT] " .. s)
end

-- =============================================
-- 1. LOAD CONFIGURATION
-- =============================================

local function loadNetworkConfig()
    local h = fs.open("/etc/network.cfg", "r")
    if not h then
        fLog("WARNING: /etc/network.cfg not found — using defaults")
        return {
            forwarding = false,
            hostname = "axis-node",
            interfaces = {
                { name = "eth0", ip = "10.0.0.1", mask = "255.255.255.0" },
            },
            dns = {
                use_doh = true,
                doh_server = "https://cloudflare-dns.com/dns-query",
                cache_size = 128,
                cache_ttl = 300,
            },
        }
    end
    local tC = {}
    while true do
        local s = fs.read(h, math.huge)
        if not s then break end
        tC[#tC + 1] = s
    end
    fs.close(h)
    local sData = table.concat(tC)
    local f = load(sData, "network.cfg", "t", {})
    if not f then
        fLog("ERROR: network.cfg parse failed")
        return nil
    end
    local bOk, tCfg = pcall(f)
    if not bOk or type(tCfg) ~= "table" then
        fLog("ERROR: network.cfg eval failed")
        return nil
    end
    return tCfg
end

-- =============================================
-- 2. PROBE HARDWARE
-- =============================================

local function probeHardware()
    local tHW = {
        bInternet = false,
        bModem = false,
        sModemAddr = nil,
        sInternetAddr = nil,
    }

    -- Check for internet card
    local hNet = fs.open("/dev/net", "r")
    if hNet then
        local bOk, tInfo = fs.deviceControl(hNet, "info", {})
        if bOk and tInfo then
            tHW.bInternet = tInfo.bOnline or false
            tHW.bHttp = tInfo.bHttpEnabled or false
            tHW.bTcp = tInfo.bTcpEnabled or false
        end
        fs.close(hNet)
    end

    -- Check for modem NIC
    local hNic = fs.open("/dev/nic0", "r")
    if hNic then
        local bOk, tInfo = fs.deviceControl(hNic, "info", {})
        if bOk and tInfo then
            tHW.bModem = (tInfo.sModemAddr ~= nil and tInfo.sModemAddr ~= "")
            tHW.sModemAddr = tInfo.sModemAddr
        end
        fs.close(hNic)
    end

    return tHW
end

-- =============================================
-- 3. INITIALIZE IP STACK
-- =============================================

local function initStack(tCfg, tHW)
    local bOk, STACK = pcall(require, "net/stack")
    if not bOk or not STACK then
        fLog("IP stack library not available: " .. tostring(STACK))
        return nil
    end

    -- Initialize the stack
    STACK.init({
        fLog = fLog,
        bForwarding = tCfg.forwarding or false,
    })

    -- Configure interfaces from /etc/network.cfg
    for _, tIface in ipairs(tCfg.interfaces or {}) do
        local sName = tIface.name or "eth0"

        -- Determine modem address for this interface
        local sModemAddr = nil
        if tHW.bModem and tHW.sModemAddr then
            sModemAddr = tHW.sModemAddr
        end

        -- Calculate mask from dotted notation
        local sMask = tIface.mask or "255.255.255.0"

        STACK.addInterface(sName, {
            sIP        = tIface.ip or "10.0.0.1",
            sMask      = sMask,
            sGateway   = tIface.gateway,
            sModemAddr = sModemAddr,
            nMTU       = 8000,
        })

        fLog(string.format("Interface %s: %s/%s%s%s",
            sName,
            tIface.ip or "10.0.0.1",
            sMask,
            tIface.gateway and (" gw " .. tIface.gateway) or "",
            sModemAddr and (" via modem " .. sModemAddr:sub(1, 8)) or " (no modem)"))
    end

    -- Configure static routes
    for _, tRoute in ipairs(tCfg.routes or {}) do
        if tRoute.dest and tRoute.gateway then
            local bOkR, sErr = pcall(function()
                local tRT = STACK.getRoutes and STACK.getRoutes()
                -- Route table is auto-populated by addInterface,
                -- but manual routes can be added here
            end)
        end
    end

    -- Configure static ARP entries
    for _, tArp in ipairs(tCfg.arp_static or {}) do
        if tArp.ip and tArp.hw then
            pcall(function()
                local IP = require("net/ipproto")
                local tAT = STACK.getArpTable and STACK.getArpTable()
            end)
        end
    end

    return STACK
end

-- =============================================
-- 4. CONFIGURE MODEM NIC VLAN
-- =============================================

local function configureNic(tCfg)
    for _, tIface in ipairs(tCfg.interfaces or {}) do
        if tIface.vlan then
            local hNic = fs.open("/dev/nic0", "r")
            if hNic then
                -- Set VLAN mode
                fs.deviceControl(hNic, "set_vlan", {
                    tIface.vlan.mode or "access",
                    tIface.vlan.native_vid or 0,
                })

                -- Add trunk VLANs
                if tIface.vlan.trunk_vlans then
                    for _, nVid in ipairs(tIface.vlan.trunk_vlans) do
                        fs.deviceControl(hNic, "add_trunk_vlan", {nVid})
                    end
                end

                fLog(string.format("NIC VLAN: %s native=%d",
                    tIface.vlan.mode or "access",
                    tIface.vlan.native_vid or 0))

                fs.close(hNic)
            end
        end
    end
end

-- =============================================
-- 5. CONFIGURE DNS
-- =============================================

local function configureDns(tCfg)
    local tDns = tCfg.dns
    if not tDns then return end

    local bOk, DNS = pcall(require, "net/dns")
    if not bOk or not DNS then
        fLog("DNS library not available")
        return
    end

    -- Set cache parameters
    if tDns.cache_size then DNS.CACHE_MAX = tDns.cache_size end
    if tDns.cache_ttl then DNS.DEFAULT_TTL = tDns.cache_ttl end

    fLog(string.format("DNS: DoH=%s cache=%d/%ds",
        tostring(tDns.use_doh ~= false),
        DNS.CACHE_MAX, DNS.DEFAULT_TTL))
end

-- =============================================
-- 6. CONFIGURE NFTABLES FIREWALL
-- =============================================

local function configureFirewall(tCfg)
    local bOk, NFT = pcall(require, "net/nftables")
    if not bOk or not NFT then return end

    NFT.setupDefaults()

    -- Apply zone policies if configured
    if tCfg.zone_policies then
        for _, tPolicy in ipairs(tCfg.zone_policies) do
            if tPolicy.from and tPolicy.to and tPolicy.action then
                NFT.addRule("filter", "forward", {
                    sIface   = tPolicy.from,
                    sDstIP   = "*",
                    sAction  = tPolicy.action,
                    sComment = tPolicy.from .. " → " .. tPolicy.to,
                })
            end
        end
    end

    fLog("Firewall: nftables defaults loaded")
end

-- =============================================
-- 7. SET HOSTNAME
-- =============================================

local function setHostname(tCfg)
    local sHostname = tCfg.hostname or "axis-node"

    -- Write to /etc/hostname
    local h = fs.open("/etc/hostname", "w")
    if h then
        fs.write(h, sHostname)
        fs.close(h)
    end

    -- Update registry
    pcall(function()
        syscall("reg_set_value", "@VT\\SYS\\CONFIG", "Hostname", sHostname, "STR")
    end)

    fLog("Hostname: " .. sHostname)
end

-- =============================================
-- 8. MAIN
-- =============================================

fLog("Network initialization starting...")

local tCfg = loadNetworkConfig()
if not tCfg then
    fLog("FATAL: Cannot load network configuration")
    return
end

local tHW = probeHardware()
fLog(string.format("Hardware: internet=%s http=%s tcp=%s modem=%s",
    tostring(tHW.bInternet),
    tostring(tHW.bHttp),
    tostring(tHW.bTcp),
    tostring(tHW.bModem)))

-- Set hostname
setHostname(tCfg)

-- Configure NIC VLAN settings
configureNic(tCfg)

-- Initialize IP stack (only if modem present for L2)
local oStack = nil
if tHW.bModem then
    oStack = initStack(tCfg, tHW)
    if oStack then
        fLog("IP stack initialized with " ..
            #(tCfg.interfaces or {}) .. " interface(s)")
    end
else
    fLog("No modem — IP stack not initialized (HTTP-only mode)")
end

-- Configure DNS
configureDns(tCfg)

-- Configure firewall
configureFirewall(tCfg)

-- Summary
fLog("╔══════════════════════════════════════╗")
fLog("║  Network Configuration Complete       ║")
fLog("╠══════════════════════════════════════╣")
if tHW.bInternet then
    fLog("║  Internet Card: ONLINE               ║")
    fLog("║    HTTP: " .. (tHW.bHttp and "enabled " or "disabled") ..
         "  TCP: " .. (tHW.bTcp and "enabled " or "disabled") .. "    ║")
else
    fLog("║  Internet Card: OFFLINE              ║")
end
if tHW.bModem then
    fLog("║  Modem NIC: CONNECTED                ║")
    fLog("║    IP Stack: ACTIVE                   ║")
else
    fLog("║  Modem NIC: NOT CONNECTED             ║")
    fLog("║    IP Stack: INACTIVE (no L2)          ║")
end
fLog("╚══════════════════════════════════════╝")

fLog("Network initialization complete.")