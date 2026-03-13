--
-- /usr/commands/qtest.lua
-- Quarantine Protection Test
--
local fs = require("filesystem")

local C = {
    R = "\27[37m", G = "\27[32m", E = "\27[31m",
    Y = "\27[33m", C = "\27[36m", D = "\27[90m",
    M = "\27[35m",
}

print(C.C .. "╔═══════════════════════════════════════════════╗" .. C.R)
print(C.C .. "║  HVCI Quarantine Protection Test               ║" .. C.R)
print(C.C .. "╚═══════════════════════════════════════════════╝" .. C.R)
print("")
print(C.D .. "  A faulty driver will be loaded and exercised." .. C.R)
print(C.D .. "  After 3 dispatch faults in <60s, quarantine triggers." .. C.R)
print("")

--  Step 1: Verify driver file exists 

print(C.Y .. "[1/5]" .. C.R .. " Checking driver file...")
local hCheck = fs.open("/drivers/quarantine_test.sys.lua", "r")
if hCheck then
    fs.close(hCheck)
    print(C.G .. "  Found /drivers/quarantine_test.sys.lua" .. C.R)
else
    print(C.E .. "  ERROR: /drivers/quarantine_test.sys.lua not found" .. C.R)
    print(C.D .. "  Place the driver file at that path and retry." .. C.R)
    return
end

--  Step 2: Load the faulty driver 

print("")
print(C.Y .. "[2/5]" .. C.R .. " Loading QuarantineTester driver...")

local bLoad, sLoadResult = syscall("driver_load", "/drivers/quarantine_test.sys.lua")

-- Let the scheduler process the load
for _ = 1, 4 do syscall("process_yield") end

if bLoad then
    print(C.G .. "  Driver loaded and initialized successfully." .. C.R)
    print(C.D .. "  (dispatch table is now corrupted — faults will occur)" .. C.R)
else
    print(C.E .. "  Load failed: " .. tostring(sLoadResult) .. C.R)
    if tostring(sLoadResult):find("Permission") then
        print(C.Y .. "  Hint: log in as root to load drivers." .. C.R)
    end
    return
end

--  Step 3: Trigger faults by opening the device repeatedly 

print("")
print(C.Y .. "[3/5]" .. C.R .. " Triggering dispatch faults...")
print("")

local bQuarantined = false

for i = 1, 5 do
    io.write(string.format("  Fault %d/5: opening /dev/qtest... ", i))

    -- Each open attempt sends a CREATE IRP to DKMS.
    -- DKMS tries: pDriverObject.tDispatch[IRP_MJ_CREATE]
    --           = false[0x00] → crash → fault recorded
    local hDev = fs.open("/dev/qtest", "r")

    -- Give DKMS time to process the fault
    for _ = 1, 3 do syscall("process_yield") end

    if hDev then
        -- Shouldn't happen (dispatch is corrupted)
        io.write(C.Y .. "opened (unexpected)" .. C.R .. "\n")
        fs.close(hDev)
    else
        -- Check if quarantine just activated
        local vQ = syscall("reg_get_value",
            "@VT\\DRV\\QuarantineTester", "Quarantined")

        if vQ == "true" or vQ == true then
            io.write(C.M .. "QUARANTINED" .. C.R .. "\n")
            bQuarantined = true
            print(C.G .. "  → Quarantine triggered after " .. i .. " faults!" .. C.R)
            break
        else
            io.write(C.E .. "fault recorded" .. C.R .. "\n")
        end
    end

    syscall("process_yield")
end

--  Step 4: Verify quarantine state in registry 

print("")
print(C.Y .. "[4/5]" .. C.R .. " Checking registry quarantine state...")

local vQuarantined = syscall("reg_get_value",
    "@VT\\DRV\\QuarantineTester", "Quarantined")
local vReason = syscall("reg_get_value",
    "@VT\\DRV\\QuarantineTester", "QuarantineReason")
local vTime = syscall("reg_get_value",
    "@VT\\DRV\\QuarantineTester", "QuarantineTime")

if vQuarantined == "true" or vQuarantined == true then
    bQuarantined = true
    print(C.G .. "  Registry: @VT\\DRV\\QuarantineTester" .. C.R)
    print(C.G .. "    Quarantined = true" .. C.R)
    if vReason then print(C.D .. "    Reason: " .. tostring(vReason) .. C.R) end
    if vTime   then print(C.D .. "    Time:   " .. tostring(vTime) .. C.R) end
else
    print(C.E .. "  Quarantined = " .. tostring(vQuarantined) .. C.R)
end

--  Step 5: Confirm post-quarantine IRP blocking 

print("")
print(C.Y .. "[5/5]" .. C.R .. " Verifying post-quarantine access is blocked...")

local hBlocked = fs.open("/dev/qtest", "r")
for _ = 1, 3 do syscall("process_yield") end

if hBlocked then
    print(C.E .. "  FAIL: device still accessible after quarantine" .. C.R)
    fs.close(hBlocked)
else
    if bQuarantined then
        print(C.G .. "  PASS: IRP blocked with STATUS_DRIVER_QUARANTINED" .. C.R)
    else
        print(C.Y .. "  Device inaccessible (quarantine not confirmed)" .. C.R)
    end
end

--  Summary 

print("")
print(C.C .. "═══════════════════════════════════════════════" .. C.R)
if bQuarantined then
    print(C.G .. "  ✓ QUARANTINE TRIGGERED SUCCESSFULLY" .. C.R)
    print("")
    print(C.D .. "  The faulty driver caused 3 dispatch crashes within" .. C.R)
    print(C.D .. "  60 seconds. HVCI quarantined it and all further" .. C.R)
    print(C.D .. "  IRPs to /dev/qtest are now blocked." .. C.R)
    print("")
    print(C.D .. "  To clear: reboot → press DEL → Drivers → Clear Quarantine" .. C.R)
else
    print(C.Y .. "  Quarantine NOT confirmed." .. C.R)
    print("")
    print(C.D .. "  Possible causes:" .. C.R)
    print(C.D .. "    • HVCI disabled (security_level=0 in /etc/pki.cfg)" .. C.R)
    print(C.D .. "    • hvci.lua not found on filesystem" .. C.R)
    print(C.D .. "    • Faults not attributable (DKMS device lookup miss)" .. C.R)
end
print(C.C .. "═══════════════════════════════════════════════" .. C.R)