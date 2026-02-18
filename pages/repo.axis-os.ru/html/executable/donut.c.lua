--
-- donut.c but lua
-- slow as hell but it works
--
fs = require("filesystem") tt = fs.open("/dev/tty","w") io = {} io.write = function(...) fs.write(tt, ...) end
            A=0 B=0 z={}b=
         {}E={32,46,44,45,126,
       58,59,61,33,42,35,36,64}S
     =math.sin C=math.cos F=math.
  floor I=io.write T=string.char W=60
  P=print H=25 P("\27[2J")for w=1,240
 do for o=0,W*H do b[o]=1 z[o]=0 end e=
 S(A)g=C(A)m=C(B)n=S(B)for j=0,6.28,.09
 do d=C(j)f=S(j)       for i=0,6.28,.04
do c=S(i)h=d+2 D        =1/(c*h*e+f*g+5)
l=C(i)t=c*h*g-            f*e x=F(W/2+W*
.3*D*(l*h*m-t*n          ))y=F(H/2+H*.6*
 D*(l*h*n+t*m))o        =x+W*y  N=math.
 max(0,F(8*((f*e-c*d*g)*m-c*d*e-f*g -l*
 d *n)))+2 if H> y and y>0 and x>0 and
  W>x and D> z[o] then  z[o]=D b[o]=N
   end end  end P( "\27[H")for k=0
     ,W* H do if k%W~=0 then I(T(
       E[b[k]]))else I( T( 10))
         end end A = A + .04
             B=B+.02 end
