-- /lib/vi/lang_lua.lua
-- Lua syntax definition for xvi
return {
  name = "Lua",
  lineComment  = "--",
  blockComment = {"--[[", "]]"},
  operators    = "+-*/%^=<>~#.;,:{}()[]",
  keywords = {
    ["if"]=1, ["then"]=1, ["else"]=1, ["elseif"]=1, ["end"]=1,
    ["do"]=1, ["while"]=1, ["for"]=1, ["repeat"]=1, ["until"]=1,
    ["break"]=1, ["return"]=1, ["function"]=1, ["local"]=1,
    ["in"]=1, ["goto"]=1, ["and"]=1, ["or"]=1, ["not"]=1,
  },
  builtins = {
    ["true"]=2, ["false"]=2, ["nil"]=2, ["self"]=2,
    ["print"]=2, ["require"]=2, ["pcall"]=2, ["xpcall"]=2,
    ["type"]=2, ["tostring"]=2, ["tonumber"]=2, ["error"]=2,
    ["pairs"]=2, ["ipairs"]=2, ["next"]=2, ["select"]=2,
    ["assert"]=2, ["unpack"]=2, ["rawset"]=2, ["rawget"]=2,
    ["setmetatable"]=2, ["getmetatable"]=2,
    ["table"]=2, ["string"]=2, ["math"]=2, ["io"]=2, ["os"]=2,
    ["coroutine"]=2, ["debug"]=2, ["load"]=2, ["loadfile"]=2,
    ["syscall"]=2, ["computer"]=2, ["component"]=2,
    ["env"]=2, ["raw_computer"]=2, ["raw_component"]=2,
  },
}