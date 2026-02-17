local tProcs = syscall("process_list")
if not tProcs then print("ps: failed"); return end

print(string.format("%-5s %-5s %-6s %-10s %s", "PID", "PPID", "RING", "STATUS", "IMAGE"))
for _, p in ipairs(tProcs) do
    print(string.format("%-5d %-5d %-6s %-10s %s",
        p.pid, p.parent, tostring(p.ring), p.status, p.image))
end