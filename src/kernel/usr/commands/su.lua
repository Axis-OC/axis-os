--
-- /usr/commands/su.lua
-- Switch User — spawns an authenticated shell as the target user.
--
-- Usage:
--   su              Switch to root (UID 0)
--   su <username>   Switch to a specific user
--

local oFs  = require("filesystem")
local oSys = require("syscall")

local tArgs = env.ARGS or {}

-- =============================================
-- ARGUMENT PARSING
-- =============================================

local sTargetUser = "root"

for _, a in ipairs(tArgs) do
    if a == "-h" or a == "--help" then
        print("Usage: su [username]")
        print("  su          Elevate to root")
        print("  su <user>   Switch to another user")
        return
    elseif a:sub(1, 1) ~= "-" then
        sTargetUser = a
    end
end

-- =============================================
-- LOAD /etc/passwd.lua (same format as init.lua)
-- =============================================

local function loadPasswd()
    local h = oFs.open("/etc/passwd.lua", "r")
    if not h then return nil end
    local sData = oFs.read(h, math.huge)
    oFs.close(h)
    if not sData or #sData == 0 then return nil end
    local f = load(sData, "passwd", "t", {})
    if not f then return nil end
    local bOk, tResult = pcall(f)
    if bOk and type(tResult) == "table" then return tResult end
    return nil
end

-- Must match the hash in /bin/init.lua exactly
local function fHash(sPassword)
    return string.reverse(sPassword) .. "AURA_SALT"
end

-- =============================================
-- MAIN
-- =============================================

local tPasswd = loadPasswd()
if not tPasswd then
    print("\27[31msu: cannot read /etc/passwd.lua\27[37m")
    return
end

local tUser = tPasswd[sTargetUser]
if not tUser then
    print("\27[31msu: unknown user '" .. sTargetUser .. "'\27[37m")
    return
end

-- Authenticate (root → anyone is free; everyone else needs password)
local nMyUid = tonumber(env.UID) or 1000
if nMyUid ~= 0 then
    io.write("Password: ")
    local sPassword = io.read()
    if not sPassword then print("\27[31msu: authentication failure\27[37m"); return end
    sPassword = sPassword:gsub("\n", "")

    if tUser.hash ~= fHash(sPassword) then
        print("\27[31msu: authentication failure\27[37m")
        return
    end
end

-- Ring: we can never spawn at a LOWER ring than our own (kernel enforces this).
local nMyRing     = syscall("process_get_ring") or 3
local nTargetRing = tUser.ring or 3
if nTargetRing < nMyRing then
    -- Can't escalate ring from userspace. Clamp to current ring.
    nTargetRing = nMyRing
end

-- Read hostname for the new shell's prompt
local sHostname = env.HOSTNAME or "localhost"

-- Spawn a new shell as the target user
local nPid, sErr = oSys.spawn(tUser.shell or "/bin/sh.lua", nTargetRing, {
    USER     = sTargetUser,
    UID      = tUser.uid,
    HOME     = tUser.home or "/",
    PWD      = tUser.home or "/",
    PATH     = env.PATH or "/usr/commands",
    HOSTNAME = sHostname,
})

if not nPid then
    print("\27[31msu: failed to start shell: " .. tostring(sErr) .. "\27[37m")
    return
end

-- Block until the elevated shell exits, then return to original shell
oSys.wait(nPid)