import sys, os
from PIL import Image, ImageDraw, ImageFont, ImageFilter
src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
def font(sz):
    for f in ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf","/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf"]:
        if os.path.exists(f): return ImageFont.truetype(f, sz)
    return ImageFont.load_default()
def panel(img, col, row, w=360, h=320, top=44, gap=26):
    x=col*w; y=top+row*(h+gap)
    return img.crop((x,y,x+w,y+h))
def grad(w,h,c1,c2):
    g=Image.new("RGB",(w,h),c1); d=ImageDraw.Draw(g)
    for y in range(h):
        t=y/h; d.line([(0,y),(w,y)],fill=tuple(int(c1[i]*(1-t)+c2[i]*t) for i in range(3)))
    return g
def title(d, text, xy, sz, fill=(255,201,60), stroke=(70,40,15), anchor="mm"):
    d.text(xy, text, font=font(sz), fill=fill, stroke_width=max(2,sz//12), stroke_fill=stroke, anchor=anchor)
bots=Image.open(f"{src}/bots.png").convert("RGB")
bosses=Image.open(f"{src}/bosses.png").convert("RGB")
maps=Image.open(f"{src}/maps.png").convert("RGB")
# icon
icon=grad(512,512,(255,214,90),(230,140,30)); d=ImageDraw.Draw(icon)
for cx,cy,r in [(70,90,26),(450,120,34),(420,430,22),(90,420,30),(260,60,16)]:
    d.ellipse([cx-r,cy-r,cx+r,cy+r],fill=(240,170,40))
ele=panel(bots,1,0).crop((40,40,320,300)).resize((470,436),Image.LANCZOS)
mask=Image.new("L",ele.size,0); ImageDraw.Draw(mask).ellipse([10,10,460,426],fill=255); mask=mask.filter(ImageFilter.GaussianBlur(8))
icon.paste(ele,(21,20),mask)
title(d,"TRUNKFALL",(256,462),62)
icon.save(f"{out}/icon_512.png")
# thumbnail helper
def thumb(name, bg, heading, sub):
    t=grad(1920,1080,(40,25,12),(15,10,5)); t.paste(bg,(0,0)); d=ImageDraw.Draw(t,"RGBA")
    d.rectangle([0,0,1920,190],fill=(20,12,5,200)); d.rectangle([0,960,1920,1080],fill=(20,12,5,200))
    title(d,heading,(960,100),92); title(d,sub,(960,1020),46,fill=(255,244,214))
    t.save(f"{out}/{name}")
# 1: bosses grid
g=Image.new("RGB",(1920,1080),(30,20,10))
cells=[(c,r) for r in range(3) for c in range(4)]
for i,(c,r) in enumerate(cells[:10]):
    p=panel(bosses,c,r).resize((384,341),Image.LANCZOS)
    g.paste(p,(int(i%5*384),190+int(i//5)*384))
thumb("thumb_1_bosses.png", g, "13 WILD BOSSES", "Squad up - stomp the mice - claim the cheese")
# 2: maps
m=maps.resize((1920,int(maps.height*1920/maps.width)),Image.LANCZOS).crop((0,40,1920,1120))
thumb("thumb_2_maps.png", m, "9 CHEESE WORLDS", "4 squads - 1 map - who extracts with the loot?")
# 3: heroes
h=Image.new("RGB",(1920,1080),(120,170,90))
for i in range(7):
    c,r=(i,0) if i<4 else (i-4,1)
    p=panel(bots,c,r).resize((480,427),Image.LANCZOS)
    h.paste(p,(int(c*480 + (240 if r==1 else 0)),200+r*380))
thumb("thumb_3_heroes.png", h, "7 ELEPHANT HEROES", "Level each class - perk trees - alt abilities - skins")
print("ok")
