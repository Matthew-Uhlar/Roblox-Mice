#!/usr/bin/env python3
"""Gem icons and prestige nameplate frames (iter2, team G). Pure PIL drawing.

    python3 assets/gems/make-art.py

Writes assets/gems/gem_t1..gem_t12.png (256x256, transparent) and
assets/frames/frame_p1/p5/p10/p20/p40/p70/p99/wheel.png (512x128, transparent
middle; slice 48 px from each edge for a 9-slice). Colours match
src/client/Visuals/GemArt.luau and PrestigeFrames.luau.
"""
import math
import os

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
FRAMES = os.path.join(os.path.dirname(HERE), "frames")

TIERS = [
    (236, 228, 196), (110, 215, 110), (50, 205, 225), (55, 100, 240), (140, 85, 240), (225, 80, 205),
    (255, 120, 150), (255, 150, 35), (235, 45, 45), (25, 150, 85), (70, 25, 75), (255, 201, 60),
]


def shade(c, f):
    if f >= 0:
        return tuple(int(v + (255 - v) * f) for v in c)
    return tuple(int(v * (1 + f)) for v in c)


def wedge_icon(tier):
    """Tiers 1-4: a cheese-wedge crystal."""
    col = TIERS[tier - 1]
    S = 1024
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([112, 112, 912, 912], fill=shade(col, 0.3) + (110,))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(60)))
    d = ImageDraw.Draw(img)
    out = (43, 26, 14, 255)
    A, B, C = (170, 560), (820, 640), (640, 230)
    h = 190
    top = [A, B, C]
    front = [A, B, (B[0], B[1] + h), (A[0], A[1] + h)]
    side = [B, C, (C[0], C[1] + h), (B[0], B[1] + h)]
    d.polygon(top, fill=shade(col, 0.35) + (255,), outline=out)
    d.polygon(front, fill=shade(col, -0.2) + (255,), outline=out)
    d.polygon(side, fill=col + (255,), outline=out)
    for hx, hy, hr in ((520, 500, 46), (640, 420, 30), (400, 700, 34), (650, 740, 28)):
        d.ellipse([hx - hr, hy - hr * 0.6, hx + hr, hy + hr * 0.6], fill=shade(col, -0.25) + (255,))
    d.line(top + [top[0]], fill=out, width=18, joint="curve")
    d.polygon([(560, 360), (575, 395), (610, 410), (575, 425), (560, 460), (545, 425), (510, 410), (545, 395)], fill=(255, 255, 255, 230))
    img.resize((256, 256), Image.LANCZOS).save(os.path.join(HERE, "gem_t%d.png" % tier))


def wheel_icon(tier):
    """Tiers 5-8: a round brilliant with a rind band."""
    col = TIERS[tier - 1]
    S = 1024
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([100, 100, 924, 924], fill=shade(col, 0.3) + (120,))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(60)))
    d = ImageDraw.Draw(img)
    out = (43, 26, 14, 255)
    cx, cy, r = 512, 512, 360
    n = 8
    pts = [(cx + r * math.cos(k / n * 2 * math.pi + math.pi / 8), cy + r * math.sin(k / n * 2 * math.pi + math.pi / 8)) for k in range(n)]
    inner = [(cx + r * 0.5 * math.cos(k / n * 2 * math.pi + math.pi / 8), cy + r * 0.5 * math.sin(k / n * 2 * math.pi + math.pi / 8)) for k in range(n)]
    for k in range(n):
        f = 0.35 * math.cos(k / n * 2 * math.pi + 2.2)
        d.polygon([pts[k], pts[(k + 1) % n], inner[(k + 1) % n], inner[k]], fill=shade(col, f) + (255,), outline=out)
    d.polygon(inner, fill=shade(col, 0.4) + (255,), outline=out)
    d.line(pts + [pts[0]], fill=out, width=20, joint="curve")
    d.ellipse([cx - r - 20, cy - r - 20, cx + r + 20, cy + r + 20], outline=shade(col, 0.5) + (255,), width=16)
    d.polygon([(420, 380), (440, 425), (485, 445), (440, 465), (420, 510), (400, 465), (355, 445), (400, 425)], fill=(255, 255, 255, 230))
    img.resize((256, 256), Image.LANCZOS).save(os.path.join(HERE, "gem_t%d.png" % tier))


def gem(tier):
    if tier <= 4:
        return wedge_icon(tier)
    if tier <= 8:
        return wheel_icon(tier)
    return crown_icon(tier)


def crown_icon(tier):
    """Tiers 9-12: a brilliant with a spiked crown."""
    col = TIERS[tier - 1]
    S = 1024
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx, cy = S / 2, S / 2 + 40
    n = 8 if tier >= 9 else 6 if tier >= 5 else 4
    w, top, mid, bot = 380, -230, -70, 330
    # glow behind
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([cx - 420, cy - 420, cx + 420, cy + 380], fill=shade(col, 0.3) + (120,))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(60)))
    d = ImageDraw.Draw(img)
    # girdle points
    pts = [(cx + w * math.cos(math.pi + k * math.pi / (n - 1)) if n > 1 else cx, cy + mid) for k in range(n)]
    xs = [cx - w + 2 * w * k / (n - 1) for k in range(n)]
    table = [(cx - w * 0.55 + 2 * w * 0.55 * k / (n - 2), cy + top) for k in range(n - 1)]
    outline = (43, 26, 14, 255)
    # crown facets
    for k in range(n - 1):
        a, b = (xs[k], cy + mid), (xs[k + 1], cy + mid)
        ta = table[min(k, len(table) - 1)]
        tb = table[min(k + 1, len(table) - 1)] if k + 1 < len(table) else table[-1]
        f = 0.35 - 0.5 * k / (n - 1)
        d.polygon([a, b, tb, ta] if k + 1 < len(table) else [a, b, ta], fill=shade(col, f) + (255,), outline=outline)
    # table top
    d.polygon([table[0], table[-1], (table[-1][0], cy + top), (table[0][0], cy + top)], fill=shade(col, 0.5) + (255,))
    # pavilion facets down to the culet
    culet = (cx, cy + bot)
    for k in range(n - 1):
        f = 0.1 - 0.6 * k / (n - 1)
        d.polygon([(xs[k], cy + mid), (xs[k + 1], cy + mid), culet], fill=shade(col, f) + (255,), outline=outline)
    # outer outline + sparkle
    d.line([(xs[0], cy + mid), table[0], table[-1], (xs[-1], cy + mid), culet, (xs[0], cy + mid)], fill=outline, width=22, joint="curve")
    for sx, sy, r in ((cx - 120, cy - 150, 60), (cx + 200, cy + 40, 36)):
        d.polygon([(sx, sy - r), (sx + r * 0.25, sy - r * 0.25), (sx + r, sy), (sx + r * 0.25, sy + r * 0.25), (sx, sy + r),
                   (sx - r * 0.25, sy + r * 0.25), (sx - r, sy), (sx - r * 0.25, sy - r * 0.25)], fill=(255, 255, 255, 230))
    for k in range(5):
        sx = cx - 300 + k * 150
        d.polygon([(sx - 40, cy + top + 10), (sx, cy + top - 150), (sx + 40, cy + top + 10)], fill=shade(col, 0.5) + (255,), outline=outline)
    if tier == 12:
        d.ellipse([cx - 440, cy - 470, cx + 440, cy + 420], outline=(255, 230, 140, 255), width=26)
    img = img.resize((256, 256), Image.LANCZOS)
    img.save(os.path.join(HERE, "gem_t%d.png" % tier))


FRAMES_DEF = [
    ("p1", (190, 140, 90), (120, 80, 50), 1),
    ("p5", (205, 210, 220), (130, 140, 155), 1),
    ("p10", (255, 201, 60), (190, 130, 30), 2),
    ("p20", (120, 210, 255), (40, 120, 200), 2),
    ("p40", (190, 120, 255), (110, 60, 190), 3),
    ("p70", (255, 110, 90), (170, 40, 40), 3),
    ("p99", (255, 240, 170), (255, 170, 40), 4),
    ("wheel", (255, 201, 60), (91, 58, 30), 5),
]


def star(d, cx, cy, r, fill, outline):
    pts = []
    for k in range(10):
        a = -math.pi / 2 + k * math.pi / 5
        rr = r if k % 2 == 0 else r * 0.45
        pts.append((cx + math.cos(a) * rr, cy + math.sin(a) * rr))
    d.polygon(pts, fill=fill, outline=outline)


def frame(name, c1, c2, stars):
    W, H, S = 512, 128, 4
    img = Image.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    out = (43, 26, 14, 255)
    m = 10 * S
    # a solid bevelled band (dark rim, bright face, highlight), transparent inside
    d.rounded_rectangle([m, m, W * S - m, H * S - m], radius=44 * S, fill=c2 + (255,))
    d.rounded_rectangle([m + 3 * S, m + 3 * S, W * S - m - 3 * S, H * S - m - 6 * S], radius=41 * S, fill=c1 + (255,))
    d.rounded_rectangle([m + 36 * S, m + 4 * S, W * S - m - 36 * S, m + 11 * S], radius=8 * S, fill=shade(c1, 0.45) + (255,))
    d.rounded_rectangle([m + 16 * S, m + 16 * S, W * S - m - 16 * S, H * S - m - 16 * S], radius=30 * S, fill=(0, 0, 0, 0))
    d.rounded_rectangle([m, m, W * S - m, H * S - m], radius=44 * S, outline=out, width=5 * S)
    d.rounded_rectangle([m + 16 * S, m + 16 * S, W * S - m - 16 * S, H * S - m - 16 * S], radius=30 * S, outline=out, width=3 * S)
    # gems on the corners for p20+
    if name in ("p20", "p40", "p70", "p99", "wheel"):
        for x in (m + 18 * S, W * S - m - 18 * S):
            d.ellipse([x - 12 * S, H * S / 2 - 12 * S, x + 12 * S, H * S / 2 + 12 * S], fill=shade(c1, 0.35) + (255,), outline=out, width=3 * S)
    # stars on top centre
    for k in range(stars):
        x = W * S / 2 + (k - (stars - 1) / 2) * 34 * S
        star(d, x, m + 4 * S, 16 * S, (255, 224, 110, 255), out)
    if name == "wheel":
        # a cheese wheel badge on the left edge
        d.ellipse([m - 4 * S, H * S / 2 - 34 * S, m + 64 * S, H * S / 2 + 34 * S], fill=(255, 205, 70, 255), outline=out, width=4 * S)
        for hx, hy, hr in ((14, -12, 7), (36, 6, 9), (20, 16, 5)):
            d.ellipse([m + hx * S - hr * S, H * S / 2 + hy * S - hr * S, m + hx * S + hr * S, H * S / 2 + hy * S + hr * S], fill=(230, 150, 30, 255))
    img = img.resize((W, H), Image.LANCZOS)
    img.save(os.path.join(FRAMES, "frame_%s.png" % name))


if __name__ == "__main__":
    os.makedirs(FRAMES, exist_ok=True)
    for t in range(1, 13):
        gem(t)
    for f in FRAMES_DEF:
        frame(*f)
    print("ok")
