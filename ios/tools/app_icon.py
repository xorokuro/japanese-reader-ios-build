import math, random
from PIL import Image, ImageDraw, ImageFilter
S=4096; random.seed(2026)
PAPER=(245,240,228); INK=(43,41,37); GOLD=(217,168,74); RUST=(176,74,60); THREAD=(184,154,106); MUTED=(150,144,132)
im=Image.new('RGB',(S,S),PAPER); d=ImageDraw.Draw(im,'RGBA')
cx,cy=S*0.5,S*0.53; R=S*0.33
# ripples
for k,r in enumerate([R*1.18,R*1.33,R*1.48]):
    pts=[(cx+math.cos(a/360*2*math.pi)*r*(1+0.004*math.sin(a/23+k)), cy+math.sin(a/360*2*math.pi)*r*(1+0.004*math.cos(a/31+k))) for a in range(0,361)]
    d.line(pts,fill=MUTED+(70,),width=6)
def figure(scale=1.0, ox=0, oy=0):
    u=R*1.55*scale
    def P(x,y): return (cx+(x-0.5)*u+ox, cy+(y-0.56)*u+oy)
    pts=[]
    # shoulders bezier from (0.12,0.95) to (0.5,0.55) to (0.88,0.95)
    def bez(p0,p1,p2,p3,n=60):
        out=[]
        for i in range(n+1):
            t=i/n; a=(1-t)**3; b=3*(1-t)**2*t; c=3*(1-t)*t*t; e=t**3
            out.append((a*p0[0]+b*p1[0]+c*p2[0]+e*p3[0], a*p0[1]+b*p1[1]+c*p2[1]+e*p3[1]))
        return out
    pts=[P(0.08,1.5)]+bez(P(0.08,1.1),P(0.08,0.72),P(0.28,0.50),P(0.5,0.50))
    pts+=bez(P(0.5,0.50),P(0.72,0.50),P(0.92,0.72),P(0.92,1.1))+[P(0.92,1.5)]
    head=(P(0.5-0.15,0.345-0.165),P(0.5+0.15,0.345+0.165))
    return pts,head,P
# figure mask
mask=Image.new('L',(S,S),0); md=ImageDraw.Draw(mask)
pts,head,P=figure()
md.polygon(pts,fill=255); md.ellipse([head[0],head[1]],fill=255)
# clip figure to inside ring
ringmask=Image.new('L',(S,S),0); ImageDraw.Draw(ringmask).ellipse([cx-R*0.97,cy-R*0.97,cx+R*0.97,cy+R*0.97],fill=255)
from PIL import ImageChops
mask=ImageChops.multiply(mask,ringmask)
fig=Image.new('RGB',(S,S),GOLD); fd=ImageDraw.Draw(fig,'RGBA')
# sashiko dots on the figure
step=int(S*0.021); row=0; y=int(cy-R)
while y<cy+R:
    x=int(cx-R)+(step//2 if row%2 else 0)
    while x<cx+R:
        r=S*0.0042
        fd.ellipse([x-r,y-r,x+r,y+r],fill=(120,84,22,150))
        x+=step
    y+=int(step*0.86); row+=1
# thread: slow S through the gap, behind ring bottom
tp=[]
for i in range(0,401):
    t=i/400; y=S*(-0.02+1.04*t); x=cx+S*0.085+math.sin(t*math.pi*1.35+0.55)*S*0.075
    tp.append((x,y))
d.line(tp,fill=THREAD+(255,),width=13,joint='curve')
im.paste(fig,(0,0),mask)
d=ImageDraw.Draw(im,'RGBA')
# figure outline
edge=mask.filter(ImageFilter.MaxFilter(15)); edge=ImageChops.subtract(edge,mask.filter(ImageFilter.MinFilter(15)))
im.paste(Image.new('RGB',(S,S),INK),(0,0),edge)
d=ImageDraw.Draw(im,'RGBA')
# wound cord ring with gap near top
start=-90+26; end=start+360-52
def ringpt(a,r): 
    w=1+0.004*math.sin(a/38.0)+0.0015*math.sin(a/9.0)
    return (cx+math.cos(math.radians(a))*r*w, cy+math.sin(math.radians(a))*r*w)
W=S*0.036
n=1400
def cord(offset,color):
    for i in range(n+1):
        a=start+(end-start)*i/n
        t=min(i,n-i)/n
        w=W*min(1.0,0.35+ (t*n/70.0)) if t*n<46 else W
        w*= (0.97+0.05*math.sin(i/90.0))
        x,y=ringpt(a,R); x+=offset[0]; y+=offset[1]
        d.ellipse([x-w/2,y-w/2,x+w/2,y+w/2],fill=color)
cord((S*0.006,S*0.009),INK+(38,))
cord((0,0),INK+(255,))
# cross ticks
for i in range(0,n,9):
    a=start+(end-start)*i/n
    if min(i,n-i)<50: continue
    lean=random.uniform(-2.2,2.2)
    p0=ringpt(a-lean*0.25,R-W*0.36); p1=ringpt(a+lean*0.25,R+W*0.36)
    d.line([p0,p1],fill=PAPER+(120,),width=7)
# spark in the opening
sx,sy=cx+S*0.012,cy-R*1.0
for k in range(8):
    a=k*math.pi/4+0.2; L=S*0.062 if k%2==0 else S*0.038
    d.line([(sx+math.cos(a)*S*0.014,sy+math.sin(a)*S*0.014),(sx+math.cos(a)*L,sy+math.sin(a)*L)],fill=RUST+(255,),width=13)
# small stars
for (x,y,r) in [(0.14,0.16,0.012),(0.86,0.2,0.009),(0.1,0.82,0.009),(0.9,0.86,0.012)]:
    d.line([(S*(x-r),S*y),(S*(x+r),S*y)],fill=MUTED+(170,),width=7); d.line([(S*x,S*(y-r)),(S*x,S*(y+r))],fill=MUTED+(170,),width=7)
im=im.resize((1024,1024),Image.LANCZOS)
# paper grain
import random as rnd
px=im.load()
noise=Image.effect_noise((1024,1024),9).convert('L')
im=Image.blend(im,Image.merge('RGB',(noise,noise,noise)),0.035)
im.save('AppIcon.png')  # copy to Sources/Assets.xcassets/AppIcon.appiconset/
im.resize((180,180),Image.LANCZOS).save('small.png')
