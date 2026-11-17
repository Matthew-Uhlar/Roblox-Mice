#!/usr/bin/env python3
"""Store art for Trunkfall (v4, team G), rendered from the CURRENT models.

    lune run scripts/render-preview.luau <scenesDir>         # export the scenes
    python3 scripts/make-store-art.py <scenesDir> [assets/store]

Uses the software renderer in scripts/render-preview.py, so every image is drawn
from the real builders (ArenaBuilder, BotModel, HeroDecor + ElephantHood,
MouseModels, BossModels): nothing goes stale when the models change.

Writes (1920x1080 thumbnails, 512x512 icon):
  icon_512.png        close-up angry chibi elephant mid-swing with flying mice and
                      a cheese wedge, sky-blue radial background, sticker outline,
                      no text (V4-B S1-4)
  thumb_1_action.png  gameplay action shot at the live camera angle: the squad
                      (two hooded player elephants + a bot) in a mouse horde,
                      the Elephante stomp ring, a boss telegraph, the melting
                      cheese storm wall, damage numbers and a HUD mock.
                      Caption "STOMP 1,000 MICE". First in the store order.
  thumb_2_bosses.png  all 13 bosses (the caption count matches the art)
  thumb_3_maps.png    6 maps at the gameplay camera (no top-down "pizzas")
  thumb_4_heroes.png  the 7 elephant heroes
A guard refuses to run when the scenes are older than BotModel.luau.
"""
import importlib.util
import math
import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("rp", os.path.join(HERE, "render-preview.py"))
rp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rp)

SRC = sys.argv[1] if len(sys.argv) > 1 else "assets/previews/_scenes"
OUT = sys.argv[2] if len(sys.argv) > 2 else "assets/store"
os.makedirs(OUT, exist_ok=True)

KEY = (1.0, 0.0, 1.0)  # chroma key for cut-out renders
GOLD = (255, 201, 60)
STROKE = (70, 40, 15)


def guard():
    bot_src = os.path.join(HERE, "..", "src", "server", "Visuals", "BotModel.luau")
    probe = os.path.join(SRC, "bot_elephante.json")
    if not os.path.exists(probe):
        sys.exit("no scenes in %s: run render-preview.luau first" % SRC)
    if os.path.exists(bot_src) and os.path.getmtime(probe) < os.path.getmtime(bot_src):
        sys.exit("scenes are older than BotModel.luau: re-export them first")


def font(sz):
    for f in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf"):
        if os.path.exists(f):
            return ImageFont.truetype(f, sz)
    return ImageFont.load_default()


def text(d, s, xy, sz, fill=GOLD, stroke=STROKE, anchor="mm"):
    d.text(xy, s, font=font(sz), fill=fill, stroke_width=max(2, sz // 11), stroke_fill=stroke, anchor=anchor)


def load(name):
    return rp.load(SRC, name)


def place(parts, x, z, yaw, y=0.0, scale=1.0, tilt=0.0):
    c, s = math.cos(yaw), math.sin(yaw)
    Ry = np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])
    ct, st = math.cos(tilt), math.sin(tilt)
    Rx = np.array([[1, 0, 0], [0, ct, -st], [0, st, ct]])
    R = Ry @ Rx
    out = []
    for p in parts:
        q = dict(p)
        cf = list(p["cf"])
        pos = R @ (np.array(cf[0:3]) * scale)
        rot = R @ np.array(cf[3:12]).reshape(3, 3)
        q["cf"] = [pos[0] + x, pos[1] + y, pos[2] + z] + list(rot.reshape(-1))
        if scale != 1.0:
            q["size"] = [v * scale for v in p["size"]]
        out.append(q)
    return out


def part(shape, size, pos, color, material="SmoothPlastic", transparency=0.0, rot=None):
    r = rot if rot is not None else np.eye(3)
    return {
        "class": "Part", "shape": shape, "size": list(size), "cf": list(pos) + list(np.array(r).reshape(-1)),
        "color": [c / 255 for c in color], "mat": material, "t": transparency,
    }


def flat_disc(x, z, d, color, y=0.08, material="Neon", transparency=0.0):
    # Cylinder along X rotated so its axis is Y
    rot = np.array([[0, -1, 0], [1, 0, 0], [0, 0, 1]])
    return part("Cylinder", (0.1, d, d), (x, y, z), color, material, transparency, rot)


def cutout(scene_parts, size, yaw=35, pitch=12, scale=1.0, lights=None):
    """Render parts on the chroma key and return an RGBA image."""
    # contact shadows (translucent dark discs) would key to purple: drop them
    scene_parts = [p for p in scene_parts if not (p.get("t", 0) > 0.3 and sum(p["color"]) < 0.4)]
    sc = {"parts": scene_parts, "lights": lights or []}
    pts = np.array([p["cf"][0:3] for p in scene_parts])
    lo, hi = pts.min(axis=0), pts.max(axis=0)
    c = (lo + hi) / 2
    ext = max(2.0, float(np.linalg.norm(hi - lo)) / 2 + 1) * scale
    dist = ext / math.tan(math.radians(20)) * 0.82
    yr, pr = math.radians(yaw), math.radians(pitch)
    eye = (c[0] - math.sin(yr) * math.cos(pr) * dist, c[1] + math.sin(pr) * dist, c[2] - math.cos(yr) * math.cos(pr) * dist)
    w, h = size[0] * 2, size[1] * 2
    cam = rp.Cam(eye, c, 40, w, h)
    rp.MAT_IDS.clear()
    img = rp.render(rp.part_polys(sc["parts"]), sc["lights"], cam, (KEY, KEY), (0.45, 0.85, -0.55),
                    (0.66, 0.66, 0.7), (1, 0.96, 0.88), KEY, 0.0, size).convert("RGB")
    a = np.asarray(img).astype(float)
    dist_key = np.sqrt((a[..., 0] - 255) ** 2 + a[..., 1] ** 2 + (a[..., 2] - 255) ** 2)
    alpha = np.clip((dist_key - 40) / 80, 0, 1)
    # despill magenta on edges
    spill = np.minimum(a[..., 0], a[..., 2]) - a[..., 1]
    fix = np.clip(spill, 0, None) * (1 - alpha)
    a[..., 0] -= fix
    a[..., 2] -= fix
    rgba = np.dstack([np.clip(a, 0, 255), alpha * 255]).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def sticker(img, outline=10, rim=4, color=(43, 26, 14)):
    """Dark sticker outline + thin white inner rim around an RGBA cut-out."""
    pad = outline + 4
    big = Image.new("RGBA", (img.width + pad * 2, img.height + pad * 2), (0, 0, 0, 0))
    big.paste(img, (pad, pad), img)
    a = big.split()[3]
    outer = a.filter(ImageFilter.MaxFilter(outline * 2 + 1))
    white = a.filter(ImageFilter.MaxFilter(rim * 2 + 1))
    base = Image.new("RGBA", big.size, color + (0,))
    base.putalpha(outer)
    w = Image.new("RGBA", big.size, (255, 255, 255, 0))
    w.putalpha(white)
    base.alpha_composite(w)
    base.alpha_composite(big)
    return base


def radial(w, h, inner, outer, cx=0.5, cy=0.45):
    y, x = np.mgrid[0:h, 0:w]
    d = np.sqrt(((x / w - cx) * 1.0) ** 2 + ((y / h - cy) * 1.0) ** 2) / 0.75
    d = np.clip(d, 0, 1)[..., None]
    arr = np.array(inner) * (1 - d) + np.array(outer) * d
    return Image.fromarray(arr.astype(np.uint8), "RGB").convert("RGBA")


def cheese_wedge(d, cx, cy, s):
    pts = [(cx - s, cy + s * 0.55), (cx + s, cy + s * 0.55), (cx + s * 0.7, cy - s * 0.55)]
    d.polygon([(px + 6, py + 6) for px, py in pts], fill=(43, 26, 14, 255))
    d.polygon(pts, fill=(255, 205, 60, 255), outline=(43, 26, 14, 255))
    for hx, hy, hr in ((0.1, 0.15, 0.14), (0.5, 0.3, 0.1), (-0.4, 0.3, 0.09)):
        d.ellipse([cx + hx * s - hr * s, cy + hy * s - hr * s, cx + hx * s + hr * s, cy + hy * s + hr * s], fill=(230, 160, 30, 255))


# ------------------------------------------------------------------ icon

def make_icon():
    ele = load("botpose_elephante_attack") or load("bot_elephante")
    hero = cutout(ele["parts"], (900, 900), yaw=-28, pitch=6, scale=0.78)
    bbox = hero.getbbox()
    hero = hero.crop(bbox)
    sc = 980 / max(hero.size)
    hero = hero.resize((int(hero.width * sc), int(hero.height * sc)), Image.LANCZOS)
    icon = radial(1024, 1024, (159, 216, 255), (78, 168, 255))
    # speed burst behind the hero
    d = ImageDraw.Draw(icon, "RGBA")
    for i in range(18):
        a = i / 18 * 6.283
        d.polygon([(512, 470), (512 + math.cos(a) * 900, 470 + math.sin(a) * 900),
                   (512 + math.cos(a + 0.12) * 900, 470 + math.sin(a + 0.12) * 900)], fill=(255, 255, 255, 38))
    mouse = load("mouse_mouse_attack")
    rnd = random.Random(5)
    for (mx, my, rot, msz) in ((110, 140, 35, 270), (860, 130, -40, 250), (880, 560, 20, 220)):
        m = cutout(mouse["parts"], (420, 420), yaw=rnd.uniform(-60, 60), pitch=20)
        m = m.crop(m.getbbox()).rotate(rot, expand=True, resample=Image.BICUBIC)
        k = msz / max(m.size)
        m = sticker(m.resize((int(m.width * k), int(m.height * k)), Image.LANCZOS), outline=6, rim=3)
        icon.alpha_composite(m, (mx - m.width // 2, my - m.height // 2))
        # crumbs popping off
        for _ in range(5):
            cx, cy = mx + rnd.uniform(-90, 90), my + rnd.uniform(-90, 90)
            r = rnd.uniform(8, 16)
            d.rectangle([cx - r, cy - r * 0.7, cx + r, cy + r * 0.7], fill=(255, 205, 60, 255), outline=(43, 26, 14, 255), width=3)
    st = sticker(hero, outline=14, rim=6)
    icon.alpha_composite(st, (512 - st.width // 2 + 10, 1024 - st.height + 40))
    cheese_wedge(ImageDraw.Draw(icon, "RGBA"), 150, 860, 120)
    icon.convert("RGB").resize((512, 512), Image.LANCZOS).save(os.path.join(OUT, "icon_512.png"))
    print("wrote icon_512.png")


# ------------------------------------------------------------------ action shot

def storm_arc(cx, cz, R, a0, a1, n=26, H=34):
    out = []
    for i in range(n):
        a = a0 + (a1 - a0) * (i + 0.5) / n
        x, z = cx + math.cos(a) * R, cz + math.sin(a) * R
        w = abs(a1 - a0) * R / n + 0.4
        yaw = -a + math.pi / 2
        c, s = math.cos(yaw), math.sin(yaw)
        rot = np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])
        out.append(part("Block", (w, H, 0.6), (x, H / 2 - 1, z), (255, 196, 64), "Glass", 0.55, rot))
        out.append(part("Ball", (2.4, 2.4, 2.4), (x, H - 1.5 + math.sin(i * 1.7) * 0.6, z), (230, 140, 30), "Neon", 0.25))
    return out


def make_action():
    mapid = "plains"
    sc = load("map_" + mapid)
    R = sc["radius"]
    fx, fz = R * 0.3, R * 0.22
    rnd = random.Random(11)
    parts = list(sc["parts"])
    squad = [("hero_elephante", 0, 0, 0.3), ("hero_ellie_fawn", -8, 5, -0.4), ("botpose_jumbo_walk", 8, 4, 0.2)]
    for name, dx, dz, yaw in squad:
        s = load(name)
        if s:
            parts += place(s["parts"], fx + dx, fz + dz, yaw)
    # stomp ring (Elephante ability) and a boss telegraph
    parts.append(flat_disc(fx, fz, 18, (255, 201, 60), y=0.1, material="SmoothPlastic", transparency=0.6))
    for i in range(24):
        a = i / 24 * 6.283
        parts.append(part("Ball", (0.6, 0.6, 0.6), (fx + math.cos(a) * 9, 0.3, fz + math.sin(a) * 9), (255, 214, 90), "Neon", 0.2))
    parts.append(flat_disc(fx - 22, fz - 16, 16, (255, 75, 62), y=0.09, material="SmoothPlastic", transparency=0.45))
    # the horde, some popping
    mix = ["mouse"] * 4 + ["rat_runner", "chonk", "crumb_slinger", "fuse_mouse", "carrier"]
    for k in range(70):
        a = rnd.uniform(0, 6.283)
        d = rnd.uniform(10, 34)
        x, z = fx + math.cos(a) * d, fz + math.sin(a) * d * 0.75
        kind = rnd.choice(mix)
        pose = "attack" if d < 15 else "walk"
        m = load("mouse_" + kind + "_" + pose)
        if m:
            fly = d < 12 and rnd.random() < 0.6
            parts += place(m["parts"], x, z, -a + math.pi / 2, y=rnd.uniform(1.5, 4) if fly else 0, tilt=rnd.uniform(-1, 1) if fly else 0)
    for _ in range(40):
        a, d = rnd.uniform(0, 6.283), rnd.uniform(4, 13)
        parts.append(part("Block", (0.5, 0.35, 0.5), (fx + math.cos(a) * d, rnd.uniform(0.3, 3), fz + math.sin(a) * d), (255, 205, 60)))
    # The Melt: the storm wall cutting across the top of the frame
    parts += storm_arc(fx, fz - 118, 95, math.radians(50), math.radians(130))
    sc = dict(sc)
    sc["parts"] = parts
    sun, sun_col, amb, fog, dens, sky = rp.scene_env(sc)
    size = (1280, 720)
    zoom = 46
    eye = (fx, zoom * math.sin(math.radians(55)), fz + zoom * math.cos(math.radians(55)))
    cam = rp.Cam(eye, (fx, 0, fz - 3), 45, size[0] * 2, size[1] * 2)
    rp.MAT_IDS.clear()
    tp = rp.terrain_polys(sc, sc.get("center", [0, 0, 0]), R + 80, sc.get("matColors", {}), (0.2, 0.55, 0.7))
    pp = rp.part_polys(parts)
    gain = 1.6 - min(1.2, sum(sun_col) / 3)
    img = rp.render(tp + pp, sc.get("lights", []), cam, sky, sun, amb, sun_col, fog, dens, size, gain)
    img = rp.grade(img, sc).resize((1920, 1080), Image.LANCZOS).convert("RGBA")
    d = ImageDraw.Draw(img, "RGBA")
    # damage numbers (own = big white / crit gold, others small)
    spots = [(gx, gy) for gx in range(520, 1420, 150) for gy in range(360, 800, 110)]
    rnd.shuffle(spots)
    for gx, gy in spots[:12]:
        x, y = gx + rnd.uniform(-30, 30), gy + rnd.uniform(-20, 20)
        crit = rnd.random() < 0.3
        n = rnd.randint(12, 48) * (3 if crit else 1)
        text(d, str(n) + ("!" if crit else ""), (x, y), 64 if crit else 44, fill=(255, 220, 40) if crit else (255, 255, 255), stroke=(60, 36, 20))
    text(d, "LEVEL UP!", (960, 300), 70, fill=GOLD)
    # HUD mock: status card, storm timer, minimap
    d.rounded_rectangle([30, 30, 470, 160], 22, fill=(30, 20, 12, 210), outline=GOLD, width=4)
    text(d, "ELEPHANTE  Lv 14", (60, 70), 34, fill=(255, 244, 214), anchor="lm")
    d.rounded_rectangle([60, 104, 440, 132], 12, fill=(70, 30, 20, 255))
    d.rounded_rectangle([60, 104, 360, 132], 12, fill=(110, 220, 110, 255))
    d.rounded_rectangle([760, 24, 1160, 96], 24, fill=(30, 20, 12, 210), outline=(255, 160, 40), width=4)
    text(d, "THE MELT  0:24", (960, 60), 38, fill=(255, 200, 80))
    d.ellipse([1680, 30, 1890, 240], fill=(60, 110, 50, 220), outline=GOLD, width=4)
    d.ellipse([1715, 65, 1855, 205], outline=(255, 170, 40), width=5)
    for dx, dy, col in ((0, 0, (255, 255, 255)), (40, -30, (235, 70, 60)), (-50, 20, (80, 150, 255)), (20, 50, (255, 200, 60))):
        d.ellipse([1785 + dx - 9, 135 + dy - 9, 1785 + dx + 9, 135 + dy + 9], fill=col + (255,), outline=(20, 12, 5, 255), width=2)
    d.rectangle([0, 950, 1920, 1080], fill=(20, 12, 5, 170))
    text(d, "STOMP 1,000 MICE", (960, 1012), 96)
    img.convert("RGB").save(os.path.join(OUT, "thumb_1_action.png"))
    print("wrote thumb_1_action.png")


# ------------------------------------------------------------------ grids

def banner(img, heading, sub):
    d = ImageDraw.Draw(img, "RGBA")
    d.rectangle([0, 0, 1920, 180], fill=(20, 12, 5, 215))
    d.rectangle([0, 960, 1920, 1080], fill=(20, 12, 5, 215))
    text(d, heading, (960, 95), 92)
    text(d, sub, (960, 1020), 46, fill=(255, 244, 214))


def make_bosses():
    ids = sorted(f[5:-5] for f in os.listdir(SRC) if f.startswith("boss_") and f.endswith(".json"))
    g = radial(1920, 1080, (120, 70, 40), (30, 18, 10))
    cols = 7
    cw, ch = 1920 // cols, 380
    for i, bid in enumerate(ids):
        sc = load("boss_" + bid)
        im = cutout(sc["parts"], (300, 300), yaw=30, pitch=15)
        im = im.crop(im.getbbox() or (0, 0, 300, 300))
        k = min((cw - 20) / im.width, (ch - 30) / im.height)
        im = sticker(im.resize((int(im.width * k), int(im.height * k)), Image.LANCZOS), outline=5, rim=2)
        row = 0 if i < cols else 1
        n_row = cols if row == 0 else len(ids) - cols
        x0 = (1920 - n_row * cw) // 2 + (i - row * cols) * cw
        g.alpha_composite(im, (x0 + (cw - im.width) // 2, 190 + row * 385 + (ch - im.height)))
    banner(g, "%d WILD BOSSES" % len(ids), "Squad up - stomp the mice - claim the cheese")
    g.convert("RGB").save(os.path.join(OUT, "thumb_2_bosses.png"))
    print("wrote thumb_2_bosses.png (%d bosses)" % len(ids))


def make_maps():
    pick = ["plains", "forest", "beach", "tundra", "volcano", "moon"]
    g = Image.new("RGBA", (1920, 1080), (20, 12, 5, 255))
    w, h = 640, 390
    for i, m in enumerate(pick):
        sc = load("map_" + m)
        if not sc:
            continue
        rp.MAT_IDS.clear()
        im = rp.render_map(sc, "close", (w, h)).convert("RGBA")
        g.alpha_composite(im, ((i % 3) * w, 180 + (i // 3) * h))
    banner(g, "9 CHEESE WORLDS", "Bigger maps - The Melt closes in - extract or gamble?")
    g.convert("RGB").save(os.path.join(OUT, "thumb_3_maps.png"))
    print("wrote thumb_3_maps.png")


def make_heroes():
    ids = sorted(f[4:-5] for f in os.listdir(SRC) if f.startswith("bot_") and f.endswith(".json"))
    g = radial(1920, 1080, (159, 216, 255), (78, 168, 255))
    d = ImageDraw.Draw(g, "RGBA")
    d.ellipse([-200, 760, 2120, 1400], fill=(110, 180, 80, 255))
    n = len(ids)
    cw = 1920 // max(1, n)
    for i, cid in enumerate(ids):
        sc = load("botpose_" + cid + "_attack") or load("bot_" + cid)
        im = cutout(sc["parts"], (420, 420), yaw=-25 + i * 8, pitch=10)
        im = im.crop(im.getbbox() or (0, 0, 420, 420))
        k = min((cw + 40) / im.width, 520 / im.height)
        im = sticker(im.resize((int(im.width * k), int(im.height * k)), Image.LANCZOS), outline=6, rim=3)
        y = 930 - im.height - (40 if i % 2 else 0)
        g.alpha_composite(im, (i * cw + (cw - im.width) // 2, y))
    banner(g, "%d ELEPHANT HEROES" % n, "You ARE the elephant - level classes - perk trees - skins")
    g.convert("RGB").save(os.path.join(OUT, "thumb_4_heroes.png"))
    print("wrote thumb_4_heroes.png")


if __name__ == "__main__":
    guard()
    which = sys.argv[3] if len(sys.argv) > 3 else "all"
    if which in ("all", "icon"):
        make_icon()
    if which in ("all", "action"):
        make_action()
    if which in ("all", "bosses"):
        make_bosses()
    if which in ("all", "maps"):
        make_maps()
    if which in ("all", "heroes"):
        make_heroes()
