import sys,re,html
from PIL import Image,ImageDraw,ImageFont
src,dst,title=sys.argv[1],sys.argv[2],sys.argv[3]
h=open(src).read(); body=re.search(r'white-space:pre;padding:6px">(.*?)</div>',h,re.S).group(1)
rows=body.split("\n"); f=ImageFont.truetype("/System/Library/Fonts/Menlo.ttc",13); cw=8; lh=16
W=110*cw+16; H=(len(rows)+2)*lh+12
img=Image.new("RGB",(W,H),"#1e1e1e"); d=ImageDraw.Draw(img)
d.rectangle([0,0,W,lh+6],fill="#333"); d.text((8,3),title,font=f,fill="#ffd866")
for y,row in enumerate(rows):
    for x,(fg,bg,ch) in enumerate(re.findall(r'color:#(\w+);background:#(\w+);[^"]*">(.*?)</span>',row)):
        px,py=8+x*cw,lh+12+y*lh
        if bg!="1e1e1e": d.rectangle([px,py,px+cw,py+lh],fill="#"+bg)
        c=html.unescape(ch)
        if c.strip(): d.text((px,py),c,font=f,fill="#"+fg)
img.save(dst)
