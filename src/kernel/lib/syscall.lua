--
-- /lib/syscall.lua
-- User-mode syscall convenience wrappers.
-- v2: Object Handle aware. Synapse token retrieval.
--

local sys = {}

sys.write = function(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  syscall("vfs_write", 1, table.concat(parts, "\t")) -- alias 1 = stdout
end

sys.read = function()
  local ok, data = syscall("vfs_read", 0) -- alias 0 = stdin
  return data
end

sys.spawn = function(path, ring_or_env, env)
  local r = 3
  local e = {}
  if type(ring_or_env) == "number" then
     r = ring_or_env
     e = env or {}
  else
     e = ring_or_env or {}
  end
  return syscall("process_spawn", path, r, e)
end

sys.wait = function(pid)
  return syscall("process_wait", pid)
end

sys.reboot = function()
  return syscall("computer_reboot")
end

sys.shutdown = function()
  return syscall("computer_shutdown")
end

-- sMLTR: get this process's synapse token
sys.getSynapseToken = function()
  return syscall("synapse_get_token")
end

-- syscall passthrough for insmod etc
sys.syscall = function(...)
  return syscall(...)
end

return sys