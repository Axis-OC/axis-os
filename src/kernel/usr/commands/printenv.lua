-- printenv - show environment variables
if not env then print("(no environment)"); return end
local tKeys = {}
for k in pairs(env) do
  if type(env[k]) ~= "table" and type(env[k]) ~= "function" then
    table.insert(tKeys, k)
  end
end
table.sort(tKeys)
for _, k in ipairs(tKeys) do
  print("\27[33m" .. k .. "\27[37m=" .. tostring(env[k]))
end