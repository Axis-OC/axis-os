-- /usr/commands/id.lua
print(string.format("uid=%s(%s) ring=%s",
    tostring(env.UID or "?"),
    tostring(env.USER or "?"),
    tostring(syscall("process_get_ring"))))