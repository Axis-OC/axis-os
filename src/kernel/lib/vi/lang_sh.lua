-- /lib/vi/lang_sh.lua
-- Shell script syntax for xvi
return {
  name = "Shell",
  lineComment  = "#",
  blockComment = nil,
  operators    = "=|&;><(){}[]!$",
  keywords = {
    ["if"]=1, ["then"]=1, ["else"]=1, ["elif"]=1, ["fi"]=1,
    ["for"]=1, ["while"]=1, ["do"]=1, ["done"]=1,
    ["case"]=1, ["esac"]=1, ["in"]=1, ["function"]=1,
    ["return"]=1, ["break"]=1, ["continue"]=1, ["exit"]=1,
    ["local"]=1, ["export"]=1, ["readonly"]=1,
  },
  builtins = {
    ["echo"]=2, ["cd"]=2, ["ls"]=2, ["cat"]=2, ["rm"]=2,
    ["cp"]=2, ["mv"]=2, ["mkdir"]=2, ["chmod"]=2, ["chown"]=2,
    ["grep"]=2, ["sed"]=2, ["awk"]=2, ["find"]=2, ["xargs"]=2,
    ["true"]=2, ["false"]=2, ["test"]=2, ["source"]=2, ["exec"]=2,
    ["read"]=2, ["shift"]=2, ["set"]=2, ["unset"]=2, ["eval"]=2,
  },
}