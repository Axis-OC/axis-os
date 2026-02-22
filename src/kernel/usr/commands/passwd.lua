--
-- /usr/commands/passwd.lua
-- Change user password
--

local fs = require("filesystem")
local sha = require("sha256")
local args = env.ARGS or {}

local sTargetUser = args[1] or env.USER

if not sTargetUser then
    print("Usage: passwd [username]")
    return
end

local nMyUid = env.UID or 1000
if sTargetUser ~= env.USER and nMyUid ~= 0 then
    print("Permission denied: only root can change other users' passwords.")
    return
end

-- Read DB
local h = fs.open("/etc/passwd.lua", "r")
if not h then
    print("Error: Cannot read /etc/passwd.lua")
    return
end
local sData = fs.read(h, math.huge)
fs.close(h)

local f = load(sData, "passwd", "t", {})
if not f then print("Error: passwd.lua is corrupt"); return end
local tDb = f()

if not tDb[sTargetUser] then
    print("Error: User '" .. sTargetUser .. "' does not exist.")
    return
end

local function promptPassword(sPrompt)
    local hIn = fs.open("/dev/tty", "r")
    fs.deviceControl(hIn, "set_mode", {"raw"})
    io.write(sPrompt)
    local tChars = {}
    while true do
        local c = fs.read(hIn, 1)
        if not c or c == "\n" or c == "\r" then break end
        if c == "\b" or c == "\127" then
            if #tChars > 0 then table.remove(tChars) end
        else
            tChars[#tChars + 1] = c
        end
    end
    fs.deviceControl(hIn, "set_mode", {"cooked"})
    fs.close(hIn)
    io.write("\n")
    return table.concat(tChars)
end

-- If not root, require old password
if nMyUid ~= 0 then
    local sOld = promptPassword("Current password: ")
    local sActualHash
    if tDb[sTargetUser].salt then
        sActualHash = sha.hex(sha.digest(tDb[sTargetUser].salt .. sOld))
    else
        sActualHash = string.reverse(sOld) .. "AURA_SALT"
    end
    
    if sActualHash ~= tDb[sTargetUser].hash then
        print("Authentication failure.")
        return
    end
end

local sNew1 = promptPassword("New password: ")
if #sNew1 < 3 then
    print("Error: Password too short.")
    return
end

local sNew2 = promptPassword("Retype new password: ")
if sNew1 ~= sNew2 then
    print("Error: Passwords do not match.")
    return
end

-- Generate new salt and hash
local sSeed = tostring(math.random()) .. tostring(os.clock())
local sSalt = sha.hex(sha.digest(sSeed)):sub(1, 8)
local sHash = sha.hex(sha.digest(sSalt .. sNew1))

tDb[sTargetUser].salt = sSalt
tDb[sTargetUser].hash = sHash

-- Save
local function serializeDB(db)
    local t = {"-- AxisOS Password File\nreturn {"}
    for user, info in pairs(db) do
        t[#t+1] = string.format("  [%q] = {", user)
        t[#t+1] = string.format("    uid = %d,", info.uid)
        t[#t+1] = string.format("    home = %q,", info.home)
        t[#t+1] = string.format("    shell = %q,", info.shell)
        t[#t+1] = string.format("    salt = %q,", info.salt)
        t[#t+1] = string.format("    hash = %q,", info.hash)
        t[#t+1] = string.format("    ring = %d", info.ring)
        t[#t+1] = "  },"
    end
    t[#t+1] = "}\n"
    return table.concat(t, "\n")
end

local hW = fs.open("/etc/passwd.lua", "w")
if not hW then
    print("Error: Cannot write to /etc/passwd.lua")
    return
end
fs.write(hW, serializeDB(tDb))
fs.close(hW)

print("Password updated successfully.")