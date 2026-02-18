-- /lib/vi/lang_c.lua
-- C/C++ syntax definition for xvi
return {
  name = "C",
  lineComment  = "//",
  blockComment = {"/*", "*/"},
  operators    = "+-*/%=<>!&|^~?:;,.{}()[]",
  keywords = {
    ["if"]=1, ["else"]=1, ["while"]=1, ["for"]=1, ["do"]=1,
    ["switch"]=1, ["case"]=1, ["default"]=1, ["break"]=1,
    ["continue"]=1, ["return"]=1, ["goto"]=1, ["typedef"]=1,
    ["struct"]=1, ["union"]=1, ["enum"]=1, ["sizeof"]=1,
    ["static"]=1, ["extern"]=1, ["const"]=1, ["volatile"]=1,
    ["register"]=1, ["inline"]=1, ["class"]=1, ["public"]=1,
    ["private"]=1, ["protected"]=1, ["virtual"]=1, ["namespace"]=1,
    ["using"]=1, ["template"]=1, ["new"]=1, ["delete"]=1,
    ["try"]=1, ["catch"]=1, ["throw"]=1, ["auto"]=1,
  },
  builtins = {
    ["int"]=2, ["char"]=2, ["float"]=2, ["double"]=2, ["void"]=2,
    ["long"]=2, ["short"]=2, ["unsigned"]=2, ["signed"]=2,
    ["bool"]=2, ["true"]=2, ["false"]=2, ["NULL"]=2, ["nullptr"]=2,
    ["size_t"]=2, ["uint8_t"]=2, ["uint16_t"]=2, ["uint32_t"]=2,
    ["int8_t"]=2, ["int16_t"]=2, ["int32_t"]=2, ["int64_t"]=2,
    ["printf"]=2, ["scanf"]=2, ["malloc"]=2, ["free"]=2,
    ["memcpy"]=2, ["strlen"]=2, ["strcmp"]=2, ["strcpy"]=2,
    ["stdout"]=2, ["stderr"]=2, ["stdin"]=2,
    ["include"]=2, ["define"]=2, ["ifdef"]=2, ["ifndef"]=2,
    ["endif"]=2, ["elif"]=2, ["pragma"]=2, ["undef"]=2,
    ["string"]=2, ["vector"]=2, ["map"]=2, ["cout"]=2, ["cin"]=2,
  },
}