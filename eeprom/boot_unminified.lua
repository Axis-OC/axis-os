local cp,cm,un=component,computer,unicode
local g,s
for a,t in cp.list() do
 if t=="gpu" then g=cp.proxy(a) end
 if t=="screen" then s=a end
end
if not g or not s then cm.beep(1000,0.2) error("NO GPU") end
g.bind(s)
local mw,mh=g.maxResolution()
g.setResolution(mw,mh)
local w,h=g.getResolution()

local args={lvl="Info",safe="Disabled",wait="2",quick="Disabled",init="/bin/init.lua"}
local CB,CR,CY,CW,CG,CK=0x0000AA,0xAA0000,0xFFFF00,0xFFFFFF,0xC0C0C0,0x000000

local function col(b,f) g.setBackground(b) g.setForeground(f) end
local function cl(b) col(b,CG) g.fill(1,1,w,h," ") end
local function cen(y,t,f) if f then g.setForeground(f) end g.set(math.floor((w-un.len(t))/2),y,t) end
local function box(x,y,bw,bh)
 local H=string.rep("=",bw-2)
 g.set(x,y,"+"..H.."+"); g.set(x,y+bh-1,"+"..H.."+")
 for i=1,bh-2 do g.set(x,y+i,"|"); g.set(x+bw-1,y+i,"|") end
end
local function key(t) return cm.pullSignal(t) end

local menu={
 {l="Standard Features",t="sub",i={
 }},
 {l="Advanced Features",t="sub",i={
  {id="quick",l="Quick Boot",o={"Enabled","Disabled"}},
  {id="wait",l="Boot Delay",t="inp"},
  {id="init",l="Init Path",t="inp"},
 }},
 {l="Chipset Features",t="sub",i={
  {id="lvl",l="Log Level",o={"Debug","Info","Warn","Error"}},
  {id="safe",l="Safe Mode",o={"Enabled","Disabled"}},
 }},
 {l="Save & Exit",t="act",f=function() return true end},
 {l="Exit No Save",t="act",f=function() cm.shutdown(true) end},
}

local function r_sub(m)
 local s,its=1,m.i
 local bw,bh=math.floor(w*0.8),#its+4
 local bx,by=math.floor((w-bw)/2),math.floor((h-bh)/2)
 while true do
  col(CB,CG) g.fill(bx,by,bw,bh," "); box(bx,by,bw,bh)
  col(CG,CK) g.set(bx+2,by," "..m.l.." ")
  for i,it in ipairs(its) do
   local y,v=by+1+i,args[it.id]
   if it.v then v=it.v end; if not v then v="" end
   local p=(bw-4)-un.len(it.l)-un.len(v)
   local txt=" "..it.l..string.rep(" ",p)..v.." "
   if i==s then col(CR,CW) else col(CB,CG) end
   g.set(bx+2,y,txt)
  end
  local e,_,c,k=key()
  if e=="key_down" then
   if k==1 or k==14 then return
   elseif k==200 and s>1 then s=s-1
   elseif k==208 and s<#its then s=s+1
   elseif k==28 then
    local it=its[s]
    if it.o then
     local idx=1; for j,x in ipairs(it.o) do if x==args[it.id] then idx=j end end
     idx=idx+1; if idx>#it.o then idx=1 end; args[it.id]=it.o[idx]
    elseif it.t=="inp" then
     col(CR,CW); local iw,ih=30,3; local ix,iy=math.floor((w-iw)/2),math.floor((h-ih)/2)
     g.fill(ix,iy,iw,ih," "); box(ix,iy,iw,ih); local inp=""
     while true do
      g.set(ix+2,iy+1,inp.."_  "); local e2,_,cc,kk=key()
      if e2=="key_down" then
       if kk==28 then args[it.id]=inp; break
       elseif kk==14 then inp=un.sub(inp,1,-2)
       elseif cc>32 and cc<127 and un.len(inp)<(iw-4) then inp=inp..un.char(cc) end
      end
     end
    end
   end
  end
 end
end

local function setup()
 local s,mh=1,h-6
 while true do
  cl(CB); col(CG,CK); g.fill(1,1,w,1," "); cen(1,"AXIS BIOS SETUP UTILITY")
  col(CB,CW); box(2,3,w-4,mh); box(2,h-3,w-4,4)
  col(CB,CY); g.set(4,h-2,"Esc:Quit  ARROWS:Select  Enter:Open  F10:Save")
  for i,m in ipairs(menu) do
   local x,y,bw=4,3+i,w-8
   local lbl=m.l; if m.t=="sub" then lbl="> "..lbl end
   if i==s then col(CR,CW); lbl=lbl..string.rep(" ",bw-un.len(lbl)) else col(CB,CY) end
   g.set(x,y,lbl)
  end
  local e,_,_,k=key()
  if e=="key_down" then
   if k==200 then s=s-1; if s<1 then s=#menu end
   elseif k==208 then s=s+1; if s>#menu then s=1 end
   elseif k==1 then return
   elseif k==68 or k==28 then
    local m=menu[s]
    if m.t=="sub" then r_sub(m)
    elseif m.t=="act" then if m.f() then return end end
   end
  end
 end
end

local logo={
 "    _        _         ___  ____  ",
 "   / \\  __ _(_)______/ _ \\/ ___| ",
 "  / _ \\ \\ \\/ / / __| | | \\___ \\ ",
 " / ___ \\ >  <| \\__ \\ |_| |___) |",
 "/_/   \\_/_/\\_\\_|___/\\___/|____/ "
}

local function splash()
 cl(CK); col(CK,CW)
 g.set(1,1,"AxisBIOS v0.82-DQA PA"); g.set(1,2,"(C) 2026 Axis Corp")
 g.set(1,4,"Xen Microkernel - Tier 3")
 local tot=cm.totalMemory(); local cur=0; local st=math.ceil(tot/15)
 while cur<tot do
  cur=cur+st; if cur>tot then cur=tot end
  g.set(1,5,"Mem Check: "..(cur//1024).."K")
  local s,_,_,k=cm.pullSignal(0.01)
  if s=="key_down" and k==211 then return "S" end
 end
 g.set(1,5,"Mem Check: "..(tot//1024).."K OK"); cm.beep(1100,0.1)
 col(CK,CG); local ly=math.floor(h/3)
 for i,l in ipairs(logo) do cen(ly+i,l) end
 col(CK,CW); cen(h-2,"Press DEL to enter SETUP",CG)
 local d=tonumber(args.wait) or 2
 if args.quick=="Enabled" then d=0.1 end
 local t=cm.uptime()+d
 while cm.uptime()<t do
  local s,_,_,k=cm.pullSignal(0.1)
  if s=="key_down" and k==211 then return "S" end
 end
end

if splash()=="S" then cm.beep(1000,0.1); setup(); splash() end

local fa
for a in cp.list("filesystem") do
 if cp.proxy(a).exists("/kernel.lua") then fa=a; break end
end
if not fa then cl(CK); g.set(1,1,"NO SYSTEM DISK"); while true do cm.pullSignal() end end

cl(CK); g.set(1,1,"Booting AxisOS...")
local p=cp.proxy(fa)
local hf=p.open("/kernel.lua","r")
cm.beep(900,0.2)
local c=""
while true do local d=p.read(hf,math.huge); if not d then break end; c=c..d end
p.close(hf)
if c:sub(1,3)=="\239\187\191" then c=c:sub(4) end
local env={raw_component=cp,raw_computer=cm,boot_fs_address=fa,boot_args=args}
setmetatable(env,{__index=_G})
local f,e=load(c,"=kernel","t",env)
if not f then error(e) end
f()