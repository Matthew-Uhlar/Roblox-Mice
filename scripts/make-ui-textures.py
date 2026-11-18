#!/usr/bin/env python3
"""Generates Trunkfall's UI texture set (warm cheese-and-wood cartoon style).

    python3 scripts/make-ui-textures.py               # writes assets/ui/*.png + slices.json
                                                      # + src/client/UI/SkinSlices.luau
    python3 scripts/make-ui-textures.py --preview DIR # also renders sheet.png and the
                                                      # shop / lobby mocks into DIR

Needs Pillow and numpy (`pip install pillow numpy`). Deterministic and headless:
every random number comes from a fixed seed, every shape is drawn at 4x and
box-downsampled (crisp anti-aliased edges). One light direction for the whole
set: from the top-left.

Every 9-slice texture records in slices.json (and SkinSlices.luau, which the
client reads through UI/Skin):
    size   [w, h]            texture size in px
    center [x0, y0, x1, y1]  SliceCenter rect (Roblox Rect.new(x0, y0, x1, y1))
    pad    [l, t, r, b]      transparent margin around the visible frame (drop
                             shadow / glow); the skin draws the image this much
                             bigger than its GuiObject so the frame edge matches
    scale  number            preferred SliceScale (design px per texture px)
    inset  [l, t, r, b]      (bars only) where the fill sits inside the frame
Upload: the files are listed in assets/models/manifest.json (type Image) and the
"Upload assets" workflow writes their ids into src/shared/Config/AssetIds.luau.
"""

import json
import math
import os
import sys

try:
    import numpy as np
    from PIL import Image, ImageDraw, ImageFont
except ImportError:  # pragma: no cover
    sys.exit("make-ui-textures.py needs Pillow and numpy: pip install pillow numpy")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "assets", "ui")
SLICES_JSON = os.path.join(OUT_DIR, "slices.json")
SLICES_LUAU = os.path.join(ROOT, "src", "client", "UI", "SkinSlices.luau")
MANIFEST = os.path.join(ROOT, "assets", "models", "manifest.json")

SS = 4  # supersampling factor
LIGHT = (-0.55, -0.83)  # direction towards the light (image coords, y down): top-left

F32 = np.float32

# ---------------------------------------------------------------- palette

INK = (54, 32, 16)
OUTLINE = (58, 34, 17)
SHADOW = (30, 16, 6)
WHITE = (255, 255, 255)
CREAM = (255, 244, 214)
GOLD_HI = (255, 240, 170)
GOLD = (255, 204, 51)
GOLD_DEEP = (196, 128, 22)
PINK = (242, 167, 181)


def rgb(c):
    return np.array(c[:3], F32) / 255.0


def lerp(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def lighten(c, t):
    return lerp(c, WHITE, t)


def darken(c, t):
    return lerp(c, (0, 0, 0), t)


# ---------------------------------------------------------------- canvas


class Canvas:
    """RGBA float canvas at SS x the final size (straight alpha)."""

    def __init__(self, w, h):
        self.w, self.h = w, h
        self.W, self.H = w * SS, h * SS
        self.rgb = np.zeros((self.H, self.W, 3), F32)
        self.a = np.zeros((self.H, self.W), F32)
        ys, xs = np.mgrid[0 : self.H, 0 : self.W].astype(F32)
        # pixel centres in FINAL px units
        self.X = (xs + 0.5) / SS
        self.Y = (ys + 0.5) / SS

    # colour: an (r, g, b) tuple 0..255 or an HxWx3 float array 0..1
    def paint(self, color, mask, opacity=1.0):
        a = np.clip(mask * opacity, 0, 1).astype(F32)
        c = rgb(color) if isinstance(color, tuple) else color
        out_a = a + self.a * (1 - a)
        safe = np.where(out_a > 1e-6, out_a, 1)[..., None]
        self.rgb = (c * a[..., None] + self.rgb * (self.a * (1 - a))[..., None]) / safe
        self.a = out_a

    # paints only where the canvas is already opaque (keeps alpha)
    def tint(self, color, mask, opacity=1.0):
        a = np.clip(mask * opacity, 0, 1)[..., None]
        c = rgb(color) if isinstance(color, tuple) else color
        self.rgb = self.rgb * (1 - a) + c * a

    def erase(self, mask):
        self.a = self.a * (1 - np.clip(mask, 0, 1))

    def image(self):
        pre = np.concatenate([self.rgb * self.a[..., None], self.a[..., None]], axis=2)
        pre = pre.reshape(self.h, SS, self.w, SS, 4).mean(axis=(1, 3))
        a = pre[..., 3:4]
        col = np.where(a > 1e-6, pre[..., :3] / np.maximum(a, 1e-6), 0)
        out = np.concatenate([col, a], axis=2)
        out = np.clip(np.round(out * 255), 0, 255).astype(np.uint8)
        # fully transparent pixels: zero colour (smaller, deterministic PNGs)
        out[out[..., 3] == 0] = 0
        return Image.fromarray(out, "RGBA")


# ---------------------------------------------------------------- masks


def _draw(c):
    img = Image.new("L", (c.W, c.H), 0)
    return img, ImageDraw.Draw(img)


def _np(img):
    return np.asarray(img, dtype=F32) / 255.0


def _s(v):
    return [x * SS for x in v]


def m_rrect(c, x0, y0, x1, y1, r):
    img, d = _draw(c)
    d.rounded_rectangle(_s([x0, y0, x1, y1]), radius=r * SS, fill=255)
    return _np(img)


def m_rrect_top(c, x0, y0, x1, y1, r):
    """Rounded top corners only."""
    img, d = _draw(c)
    d.rounded_rectangle(_s([x0, y0, x1, y1]), radius=r * SS, fill=255, corners=(True, True, False, False))
    return _np(img)


def m_ellipse(c, cx, cy, rx, ry=None):
    ry = rx if ry is None else ry
    img, d = _draw(c)
    d.ellipse(_s([cx - rx, cy - ry, cx + rx, cy + ry]), fill=255)
    return _np(img)


def m_poly(c, pts):
    img, d = _draw(c)
    d.polygon([(x * SS, y * SS) for x, y in pts], fill=255)
    return _np(img)


def m_line(c, pts, width, caps=True):
    img, d = _draw(c)
    d.line([(x * SS, y * SS) for x, y in pts], fill=255, width=int(width * SS), joint="curve")
    if caps:
        r = width * SS / 2
        for x, y in (pts[0], pts[-1]):
            d.ellipse([x * SS - r, y * SS - r, x * SS + r, y * SS + r], fill=255)
    return _np(img)


def m_arc(c, cx, cy, r, a0, a1, width):
    img, d = _draw(c)
    d.arc(_s([cx - r, cy - r, cx + r, cy + r]), a0, a1, fill=255, width=int(width * SS))
    return _np(img)


def m_rot_rect(c, cx, cy, w, h, deg, r=0):
    """Rotated rectangle (r > 0 rounds it with a blur threshold)."""
    a = math.radians(deg)
    ca, sa = math.cos(a), math.sin(a)
    pts = []
    for px, py in ((-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)):
        pts.append((cx + px * ca - py * sa, cy + px * sa + py * ca))
    m = m_poly(c, pts)
    return roundify(m, r) if r else m


def union(*ms):
    out = ms[0]
    for m in ms[1:]:
        out = np.maximum(out, m)
    return out


def sub(a, b):
    return np.clip(a - b, 0, 1)


def inter(a, b):
    return a * b


# ---------------------------------------------------------------- filters


def _box1(a, r, axis):
    if r <= 0:
        return a
    a = np.moveaxis(a, axis, 0)
    n = a.shape[0]
    p = np.pad(a, [(r, r)] + [(0, 0)] * (a.ndim - 1))
    cs = np.cumsum(p, axis=0, dtype=np.float64)
    cs = np.concatenate([np.zeros((1,) + cs.shape[1:]), cs], axis=0)
    out = (cs[2 * r + 1 : 2 * r + 1 + n] - cs[:n]) / (2 * r + 1)
    return np.moveaxis(out.astype(F32), 0, axis)


def blur(m, sigma):
    """Gaussian-ish blur (3 box passes); sigma in FINAL px."""
    r = max(0, int(round(sigma * SS)))
    for _ in range(3):
        m = _box1(_box1(m, r, 0), r, 1)
    return m


def shift(m, dx, dy):
    """Shift by final px (zero fill)."""
    sx, sy = int(round(dx * SS)), int(round(dy * SS))
    out = np.zeros_like(m)
    H, W = m.shape[:2]
    ys0, ys1 = max(0, sy), min(H, H + sy)
    xs0, xs1 = max(0, sx), min(W, W + sx)
    out[ys0:ys1, xs0:xs1] = m[ys0 - sy : ys1 - sy, xs0 - sx : xs1 - sx]
    return out


def dilate(m, r):
    """Dilate by r final px (alternating square / cross steps ~ a disk)."""
    steps = int(round(r * SS))
    out = m
    for i in range(steps):
        p = np.pad(out, 1)
        if i % 2 == 0:
            out = np.maximum.reduce(
                [p[1:-1, 1:-1], p[:-2, 1:-1], p[2:, 1:-1], p[1:-1, :-2], p[1:-1, 2:]]
            )
        else:
            out = np.maximum.reduce(
                [p[1:-1, 1:-1], p[:-2, :-2], p[:-2, 2:], p[2:, :-2], p[2:, 2:], p[:-2, 1:-1], p[2:, 1:-1], p[1:-1, :-2], p[1:-1, 2:]]
            )
    return out


def erode(m, r):
    return 1 - dilate(1 - m, r)


def roundify(m, r):
    """Rounds sharp corners: blur, then re-threshold with a soft edge."""
    b = blur(m, r * 0.5)
    return np.clip((b - 0.5) * 6 + 0.5, 0, 1)


def emboss(c, mask, width, hi=0.45, lo=0.35, clip=None, light=LIGHT):
    """Pillow bevel lit from the light direction, painted inside `mask`."""
    b = blur(mask, width)
    gy, gx = np.gradient(b)
    s = -(gx * light[0] + gy * light[1]) * (width * SS * 2.5)
    region = mask if clip is None else clip
    c.tint(WHITE, np.clip(s, 0, 1) * region, hi)
    c.tint(SHADOW, np.clip(-s, 0, 1) * region, lo)


def inner_shadow(c, mask, width, dx=0, dy=0, color=SHADOW, opacity=0.5):
    inv = shift(blur(1 - mask, width), dx, dy)
    c.tint(color, inv * mask, opacity)


def drop_shadow(c, mask, dx, dy, sigma, opacity=0.5, color=SHADOW):
    c.paint(color, blur(shift(mask, dx, dy), sigma), opacity)


def glow(c, mask, sigma, color, opacity):
    c.paint(color, np.clip(blur(mask, sigma) * 1.6, 0, 1), opacity)


# ---------------------------------------------------------------- fills


def vgrad(c, stops, y0=None, y1=None):
    """Vertical gradient: stops = [(t, color), ...] between y0 and y1 (final px)."""
    y0 = 0 if y0 is None else y0
    y1 = c.h if y1 is None else y1
    t = np.clip((c.Y - y0) / max(1e-6, y1 - y0), 0, 1)
    ts = [s[0] for s in stops]
    out = np.zeros((c.H, c.W, 3), F32)
    for ch in range(3):
        out[..., ch] = np.interp(t, ts, [s[1][ch] / 255.0 for s in stops])
    return out


def radial(c, cx, cy, r, stops):
    t = np.clip(np.hypot(c.X - cx, c.Y - cy) / r, 0, 1)
    ts = [s[0] for s in stops]
    out = np.zeros((c.H, c.W, 3), F32)
    for ch in range(3):
        out[..., ch] = np.interp(t, ts, [s[1][ch] / 255.0 for s in stops])
    return out


def value_noise(c, cell_x, cell_y, seed, wrap_x=False):
    """Smooth noise 0..1, cells of cell_x x cell_y final px (bicubic)."""
    rng = np.random.default_rng(seed)
    gw = max(2, int(math.ceil(c.w / cell_x)))
    gh = max(2, int(math.ceil(c.h / cell_y)))
    grid = rng.random((gh + 4, gw + 4)).astype(F32)
    if wrap_x:
        grid[:, gw : gw + 4] = grid[:, 0:4]
        grid[:, gw + 2 : gw + 4] = grid[:, 2:4]
    img = Image.fromarray((grid * 255).astype(np.uint8), "L")
    big = img.resize(((gw + 4) * cell_x * SS, (gh + 4) * cell_y * SS), Image.BICUBIC)
    arr = np.asarray(big, dtype=F32) / 255.0
    return arr[: c.H, : c.W]


def wood(c, direction, seed, light=(196, 136, 78), dark=(132, 82, 42), freq=0.55):
    """Wood grain RGB array; direction 'h' (grain along x) or 'v'."""
    if direction == "h":
        n1 = value_noise(c, 48, 10, seed)
        n2 = value_noise(c, 160, 3, seed + 1)
        u, v = c.X, c.Y
    else:
        n1 = value_noise(c, 10, 48, seed)
        n2 = value_noise(c, 3, 160, seed + 1)
        u, v = c.Y, c.X
    t = v * freq + n1 * 7.0 + np.sin(u * 0.045 + n1 * 3) * 1.4
    g = 0.5 + 0.5 * np.sin(t)
    g = g ** 2.2
    streak = (n2 - 0.5) * 0.55
    k = np.clip(g * 0.75 + 0.15 + streak, 0, 1)[..., None]
    return rgb(dark) * (1 - k) + rgb(light) * k


# ---------------------------------------------------------------- registry

TEXTURES = {}  # name -> {"img": Image, "slice": {...} or None, "group": str}


def save(name, canvas, group, slice_info=None):
    TEXTURES[name] = {"img": canvas.image(), "slice": slice_info, "group": group}


def slice_rec(size, center, pad, scale, **extra):
    d = {"size": list(size), "center": list(center), "pad": list(pad), "scale": scale}
    d.update(extra)
    return d


# ---------------------------------------------------------------- shared pieces


def rivet(c, x, y, r):
    m = m_ellipse(c, x, y, r)
    drop_shadow(c, m, 0.8, 1.5, 1.2, 0.55)
    c.paint(OUTLINE, m_ellipse(c, x, y, r + 1.2))
    c.paint(radial(c, x - r * 0.35, y - r * 0.4, r * 1.6, [(0, (255, 246, 200)), (0.45, (232, 178, 70)), (1, (130, 80, 22))]), m)
    c.paint(WHITE, m_ellipse(c, x - r * 0.35, y - r * 0.4, r * 0.32, r * 0.22), 0.85)


def gem(c, x, y, r, color, sides=8, rot=22.5):
    pts = [(x + r * math.cos(math.radians(rot + i * 360 / sides)), y + r * math.sin(math.radians(rot + i * 360 / sides))) for i in range(sides)]
    m = m_poly(c, pts)
    drop_shadow(c, m, 0.8, 1.6, 1.4, 0.6)
    c.paint(OUTLINE, dilate(m, 1.2))
    # gold setting
    c.paint(radial(c, x - r * 0.3, y - r * 0.3, r * 1.5, [(0, GOLD_HI), (0.6, GOLD), (1, GOLD_DEEP)]), m)
    inner = [(x + r * 0.68 * math.cos(math.radians(rot + i * 360 / sides)), y + r * 0.68 * math.sin(math.radians(rot + i * 360 / sides))) for i in range(sides)]
    mi = m_poly(c, inner)
    c.paint(radial(c, x - r * 0.25, y - r * 0.3, r * 1.1, [(0, lighten(color, 0.6)), (0.5, color), (1, darken(color, 0.45))]), mi)
    # facets: light upper-left wedges, dark lower-right
    for i in range(sides):
        a0 = rot + i * 360 / sides
        a1 = rot + (i + 1) * 360 / sides
        mid = math.radians((a0 + a1) / 2)
        p = [(x, y), inner[i], inner[(i + 1) % sides]]
        lit = -(math.cos(mid) * LIGHT[0] + math.sin(mid) * LIGHT[1])
        fm = m_poly(c, p)
        if lit < 0:
            c.tint(WHITE, fm * mi, min(0.4, -lit * 0.4))
        else:
            c.tint(SHADOW, fm * mi, min(0.35, lit * 0.35))
    c.paint(WHITE, m_ellipse(c, x - r * 0.25, y - r * 0.32, r * 0.2, r * 0.13), 0.9)


def sparkle(c, x, y, r, opacity=1.0):
    pts = []
    for i in range(8):
        a = math.radians(i * 45 - 90)
        rr = r if i % 2 == 0 else r * 0.22
        pts.append((x + rr * math.cos(a), y + rr * math.sin(a)))
    m = m_poly(c, pts)
    glow(c, m, r * 0.35, (255, 250, 210), 0.6 * opacity)
    c.paint(WHITE, m, opacity)


# ---------------------------------------------------------------- panels


def make_panel(name, dark):
    W = H = 512
    c = Canvas(W, H)
    x0, y0, x1, y1 = 14, 12, W - 14, H - 24
    R = 44
    F = 46  # frame width (incl. outline)
    outer = m_rrect(c, x0, y0, x1, y1, R)
    drop_shadow(c, outer, 0, 9, 9, 0.55)
    c.paint(OUTLINE, outer)
    frame_m = m_rrect(c, x0 + 4, y0 + 4, x1 - 4, y1 - 4, R - 4)
    if dark:
        wl, wd = (124, 80, 48), (70, 42, 24)
    else:
        wl, wd = (204, 144, 84), (138, 86, 44)
    wh = wood(c, "h", 11 if not dark else 21, wl, wd)
    wv = wood(c, "v", 12 if not dark else 22, wl, wd)
    dx = np.minimum(c.X - x0, x1 - c.X)
    dy = np.minimum(c.Y - y0, y1 - c.Y)
    horiz = (dy < dx)[..., None]
    c.paint(np.where(horiz, wh, wv), frame_m)
    # mitre seams
    seam = np.clip(1.2 - np.abs(dx - dy) * SS / 2.2, 0, 1) * (np.minimum(dx, dy) < F) * frame_m
    c.tint(SHADOW, seam, 0.45)
    emboss(c, frame_m, 5, 0.5, 0.45)
    # top sheen on the wood
    c.tint(WHITE, frame_m * np.clip(1 - (c.Y - y0) / 40, 0, 1), 0.12)
    # carved groove halfway into the frame
    g = 20
    ring_o = m_rrect(c, x0 + g, y0 + g, x1 - g, y1 - g, R - g + 4)
    ring_i = m_rrect(c, x0 + g + 3, y0 + g + 3, x1 - g - 3, y1 - g - 3, R - g + 1)
    groove = sub(ring_o, ring_i)
    c.tint(lighten(wl, 0.35), shift(groove, 1.2, 1.2) * frame_m, 0.55)
    c.tint(darken(wd, 0.45), groove, 0.85)
    # inner parchment / leather
    ix0, iy0, ix1, iy1 = x0 + F, y0 + F, x1 - F, y1 - F
    inner = m_rrect(c, ix0, iy0, ix1, iy1, 16)
    c.paint(OUTLINE, m_rrect(c, ix0 - 3, iy0 - 3, ix1 + 3, iy1 + 3, 19))
    # brass bead between wood and parchment
    bead = sub(m_rrect(c, ix0 - 2, iy0 - 2, ix1 + 2, iy1 + 2, 18), inner)
    c.paint(vgrad(c, [(0, GOLD_HI), (0.5, GOLD), (1, GOLD_DEEP)], iy0, iy1), bead)
    if dark:
        base = vgrad(c, [(0, (74, 50, 32)), (1, (46, 30, 18))], iy0, iy1)
        n = value_noise(c, 22, 22, 31)[..., None]
        base = base * (0.9 + 0.2 * n)
    else:
        base = vgrad(c, [(0, (255, 248, 224)), (0.6, (253, 238, 202)), (1, (244, 222, 178))], iy0, iy1)
        n = value_noise(c, 26, 26, 41)[..., None]
        n2 = value_noise(c, 6, 6, 42)[..., None]
        base = base * (0.95 + 0.07 * n + 0.03 * n2)
    c.paint(np.clip(base, 0, 1), inner)
    inner_shadow(c, inner, 7, 0, 3, SHADOW if dark else (120, 70, 30), 0.65 if dark else 0.42)
    # rivets in the corners of the frame
    rr = 8.5
    for (px, py) in ((x0 + F / 2 + 4, y0 + F / 2 + 4), (x1 - F / 2 - 4, y0 + F / 2 + 4), (x0 + F / 2 + 4, y1 - F / 2 - 4), (x1 - F / 2 - 4, y1 - F / 2 - 4)):
        rivet(c, px, py, rr)
    pad = (x0, y0, W - x1, H - y1)
    center = (x0 + R + 26, y0 + R + 26, x1 - R - 26, y1 - R - 26)
    save(name, c, "panels", slice_rec((W, H), center, pad, 0.42))


# ---------------------------------------------------------------- buttons

BUTTON_COLORS = {
    # face top, face bottom, lip, outline
    "primary": ((255, 226, 110), (246, 168, 28), (178, 104, 12), (96, 52, 10)),
    "secondary": ((255, 250, 232), (236, 216, 172), (176, 146, 98), (92, 62, 34)),
    "danger": ((255, 128, 110), (214, 52, 42), (140, 26, 22), (86, 18, 14)),
    "robux": ((150, 232, 120), (52, 168, 70), (26, 108, 44), (18, 66, 28)),
    "tint": ((255, 255, 255), (214, 214, 214), (150, 150, 150), (70, 70, 70)),
}


def button_body(c, box, R, cols, state, glow_color=None):
    x0, y0, x1, y1 = box
    top, bot, lipc, line = cols
    lip = 9 if state != "pressed" else 4
    press = 0 if state != "pressed" else 4
    if state == "hover":
        top, bot = lighten(top, 0.18), lighten(bot, 0.12)
    elif state == "pressed":
        top, bot = darken(top, 0.06), darken(bot, 0.1)
    outer = m_rrect(c, x0, y0 + press, x1, y1, R)
    if state == "pressed":
        drop_shadow(c, outer, 0, 2, 2.5, 0.45)
    else:
        drop_shadow(c, outer, 0, 6, 5, 0.5)
    if state == "hover":
        glow(c, outer, 5, glow_color or (255, 236, 150), 0.55)
    c.paint(line, outer)
    body = m_rrect(c, x0 + 4, y0 + 4 + press, x1 - 4, y1 - 4, R - 4)
    c.paint(lipc, body)
    face = m_rrect(c, x0 + 4, y0 + 4 + press, x1 - 4, y1 - 4 - lip, R - 4)
    fy0, fy1 = y0 + 4 + press, y1 - 4 - lip
    c.paint(vgrad(c, [(0, top), (0.55, lerp(top, bot, 0.55)), (1, bot)], fy0, fy1), face)
    # lip shading: darker toward the bottom
    lipm = sub(body, face)
    c.tint(darken(lipc, 0.3), lipm * np.clip((c.Y - (fy1 - 2)) / (lip + 4), 0, 1), 0.6)
    emboss(c, face, 3.2, 0.35, 0.28)
    # inner glossy highlight on the upper half
    hl = m_rrect(c, x0 + 14, fy0 + 5, x1 - 14, fy0 + (fy1 - fy0) * 0.48, (R - 12))
    c.tint(WHITE, hl * np.clip(1 - (c.Y - fy0 - 5) / ((fy1 - fy0) * 0.48), 0, 1) ** 0.8, 0.55 if state != "pressed" else 0.3)
    # crisp top rim light
    rim = sub(face, shift(face, 0, 2.2))
    c.tint(WHITE, rim, 0.6)
    if state == "pressed":
        inner_shadow(c, face, 4, 0, 2.5, SHADOW, 0.35)
    return face


def make_buttons():
    W, H = 256, 128
    box = (10, 8, 246, 112)
    R = 30
    for variant, cols in BUTTON_COLORS.items():
        for state in ("normal", "hover", "pressed"):
            c = Canvas(W, H)
            gc = {"primary": (255, 236, 150), "secondary": (255, 250, 220), "danger": (255, 170, 150), "robux": (190, 255, 170), "tint": (255, 255, 255)}[variant]
            button_body(c, box, R, cols, state, gc)
            name = f"ui_btn_{variant}" + ("" if state == "normal" else f"_{state}")
            pad = (box[0], box[1], W - box[2], H - box[3])
            center = (box[0] + R + 6, box[1] + R + 4, box[2] - R - 6, box[3] - R - 12)
            save(name, c, "buttons", slice_rec((W, H), center, pad, 0.42))


def make_tabs():
    W, H = 256, 128
    for active in (True, False):
        c = Canvas(W, H)
        y0 = 8 if active else 18
        x0, x1, y1 = 10, 246, 128
        R = 26
        outer = m_rrect_top(c, x0, y0, x1, y1 + 20, R)
        outer = outer * (c.Y < y1)
        drop_shadow(c, outer, 0, -1, 4, 0.35)
        c.paint(OUTLINE, outer)
        face = m_rrect_top(c, x0 + 4, y0 + 4, x1 - 4, y1 + 20, R - 4) * (c.Y < y1)
        if active:
            c.paint(vgrad(c, [(0, (255, 232, 130)), (0.6, (255, 200, 50)), (1, (240, 160, 26))], y0, y1), face)
            emboss(c, face, 3, 0.4, 0.2)
            hl = m_rrect(c, x0 + 14, y0 + 8, x1 - 14, y0 + 40, 18)
            c.tint(WHITE, hl * np.clip(1 - (c.Y - y0 - 8) / 32, 0, 1), 0.5)
            rim = sub(face, shift(face, 0, 2.2))
            c.tint(WHITE, rim, 0.65)
            # a little cheese hole pair
            for hx, hy, hr in ((206, y0 + 30, 7), (222, y0 + 50, 4)):
                hm = m_ellipse(c, hx, hy, hr, hr * 0.8)
                c.tint((214, 140, 24), hm, 0.8)
                inner_shadow(c, hm, 1.6, 0, 1.5, (150, 90, 10), 0.6)
        else:
            c.paint(vgrad(c, [(0, (236, 214, 170)), (1, (196, 166, 118))], y0, y1), face)
            emboss(c, face, 3, 0.3, 0.2)
            rim = sub(face, shift(face, 0, 2))
            c.tint(WHITE, rim, 0.4)
            # shaded bottom: tucked behind the content
            c.tint(SHADOW, face * np.clip((c.Y - (y1 - 30)) / 30, 0, 1), 0.25)
        name = "ui_tab_active" if active else "ui_tab_inactive"
        pad = (x0, y0, W - x1, 0)
        center = (x0 + R + 6, y0 + R + 6, x1 - R - 6, H - 8)
        save(name, c, "tabs", slice_rec((W, H), center, pad, 0.42))


# ---------------------------------------------------------------- cards

RARITY = {
    "common": ((236, 236, 230), (176, 176, 170), (104, 104, 100)),
    "rare": ((178, 222, 255), (78, 168, 255), (28, 84, 176)),
    "epic": ((226, 190, 255), (179, 107, 255), (92, 40, 164)),
    "legendary": ((255, 240, 160), (255, 170, 46), (172, 92, 10)),
}


def make_cards():
    W = H = 256
    x0, y0, x1, y1 = 10, 8, 246, 244
    R = 28
    # base: tintable rounded body (ImageColor3 = the card colour)
    c = Canvas(W, H)
    outer = m_rrect(c, x0, y0, x1, y1, R)
    drop_shadow(c, outer, 0, 5, 4, 0.45)
    c.paint(vgrad(c, [(0, (255, 255, 255)), (1, (226, 226, 226))], y0, y1), outer)
    n = value_noise(c, 10, 10, 77)
    c.tint((200, 200, 200), outer * n, 0.12)
    inner_shadow(c, outer, 6, 0, 2, (90, 90, 90), 0.35)
    pad = (x0, y0, W - x1, H - y1)
    center = (x0 + R + 22, y0 + R + 22, x1 - R - 22, y1 - R - 22)
    save("ui_card_base", c, "cards", slice_rec((W, H), center, pad, 0.4))
    for rar, (hi, mid, lo) in RARITY.items():
        c = Canvas(W, H)
        outer = m_rrect(c, x0, y0, x1, y1, R)
        t = 13
        inner = m_rrect(c, x0 + t, y0 + t, x1 - t, y1 - t, R - t + 4)
        ring = sub(outer, inner)
        # rarity glow inward
        glow_in = np.clip(blur(1 - inner, 12) * 1.4, 0, 1) * inner
        c.paint(mid, glow_in, 0.55)
        c.paint(OUTLINE, ring)
        c.paint(OUTLINE, sub(m_rrect(c, x0 + t - 2, y0 + t - 2, x1 - t + 2, y1 - t + 2, R - t + 6), inner))
        metal = sub(m_rrect(c, x0 + 3, y0 + 3, x1 - 3, y1 - 3, R - 3), m_rrect(c, x0 + t - 1, y0 + t - 1, x1 - t + 1, y1 - t + 1, R - t + 5))
        diag = np.clip(((c.X - x0) + (c.Y - y0)) / ((x1 - x0) + (y1 - y0)), 0, 1)
        col = np.zeros((c.H, c.W, 3), F32)
        for ch in range(3):
            col[..., ch] = np.interp(diag, [0, 0.45, 1], [hi[ch] / 255, mid[ch] / 255, lo[ch] / 255])
        c.paint(col, metal)
        emboss(c, metal, 2.5, 0.55, 0.4)
        # fine inner groove
        gr = sub(m_rrect(c, x0 + 7, y0 + 7, x1 - 7, y1 - 7, R - 7), m_rrect(c, x0 + 8.5, y0 + 8.5, x1 - 8.5, y1 - 8.5, R - 8.5))
        c.tint(darken(lo, 0.3), gr, 0.6)
        c.tint(WHITE, shift(gr, 1, 1) * metal, 0.35)
        if rar == "rare":
            for (px, py) in ((x0 + 20, y0 + 20), (x1 - 20, y0 + 20), (x0 + 20, y1 - 20), (x1 - 20, y1 - 20)):
                rivet(c, px, py, 6)
        elif rar == "epic":
            for (px, py) in ((x0 + 20, y0 + 20), (x1 - 20, y0 + 20), (x0 + 20, y1 - 20), (x1 - 20, y1 - 20)):
                gem(c, px, py, 9, (190, 120, 255), sides=4, rot=0)
        elif rar == "legendary":
            for (px, py) in ((x0 + 21, y0 + 21), (x1 - 21, y0 + 21), (x0 + 21, y1 - 21), (x1 - 21, y1 - 21)):
                gem(c, px, py, 14, (255, 60, 84), sides=8)
            # crest at the top centre (stays put: the slice centre stretches around it? no:
            # the top edge stretches, so keep the crest off the frame) -> sparkles in corners
            sparkle(c, x0 + 40, y0 + 8, 7, 0.9)
            sparkle(c, x1 - 8, y0 + 40, 6, 0.8)
        pad = (x0, y0, W - x1, H - y1)
        center = (x0 + R + 22, y0 + R + 22, x1 - R - 22, y1 - R - 22)
        save(f"ui_card_{rar}", c, "cards", slice_rec((W, H), center, pad, 0.4))


# ---------------------------------------------------------------- tags, ribbon, bar, misc


def make_price_tag():
    W, H = 256, 128
    c = Canvas(W, H)
    pts = [(44, 24), (240, 24), (240, 100), (44, 100), (12, 62)]
    body = roundify(m_poly(c, pts), 8)
    drop_shadow(c, body, 0, 5, 4, 0.5)
    c.paint(OUTLINE, dilate(body, 4))
    c.paint(vgrad(c, [(0, (255, 232, 130)), (0.6, (255, 200, 52)), (1, (232, 150, 24))], 24, 100), body)
    emboss(c, body, 3, 0.45, 0.3)
    # stitched inner line
    inner = roundify(m_poly(c, [(50, 32), (232, 32), (232, 92), (50, 92), (22, 62)]), 6)
    edge = sub(inner, erode(inner, 1.4))
    c.tint((176, 104, 12), edge, 0.7)
    hl = m_rrect(c, 50, 30, 232, 54, 10)
    c.tint(WHITE, hl * np.clip(1 - (c.Y - 30) / 24, 0, 1), 0.45)
    # hole + eyelet
    eye = m_ellipse(c, 36, 62, 9)
    c.paint(vgrad(c, [(0, (255, 248, 210)), (1, (170, 120, 40))], 53, 71), eye)
    c.paint(OUTLINE, m_ellipse(c, 36, 62, 5.5))
    c.erase(m_ellipse(c, 36, 62, 4.2))
    pad = (12, 24, W - 240 - 4, H - 100 - 4)
    center = (64, 46, 214, 80)
    save("ui_price_tag", c, "tags", slice_rec((W, H), center, (8, 20, 12, 22), 0.45))


def make_badge():
    W, H = 128, 64
    c = Canvas(W, H)
    x0, y0, x1, y1 = 6, 6, 122, 54
    R = 24
    outer = m_rrect(c, x0, y0, x1, y1, R)
    drop_shadow(c, outer, 0, 3, 2.5, 0.45)
    c.paint((70, 70, 70), outer)
    face = m_rrect(c, x0 + 3, y0 + 3, x1 - 3, y1 - 3, R - 3)
    c.paint(vgrad(c, [(0, (255, 255, 255)), (1, (200, 200, 200))], y0, y1), face)
    emboss(c, face, 2.5, 0.4, 0.25)
    hl = m_rrect(c, x0 + 9, y0 + 6, x1 - 9, y0 + 22, 8)
    c.tint(WHITE, hl * np.clip(1 - (c.Y - y0 - 6) / 16, 0, 1), 0.6)
    save("ui_badge", c, "tags", slice_rec((W, H), (x0 + R + 4, y0 + 16, x1 - R - 4, y1 - 16), (x0, y0, W - x1, H - y1), 0.4))


def make_ribbon():
    W, H = 512, 128
    c = Canvas(W, H)
    red_hi, red, red_lo = (255, 120, 96), (214, 64, 52), (138, 30, 26)
    # tails (behind)
    for side in (-1, 1):
        if side < 0:
            tail = [(10, 46), (96, 46), (96, 112), (10, 112), (34, 79)]
            fold = [(70, 96), (96, 96), (96, 112)]
        else:
            tail = [(416, 46), (502, 46), (478, 79), (502, 112), (416, 112)]
            fold = [(416, 96), (442, 96), (416, 112)]
        tm = m_poly(c, tail)
        drop_shadow(c, tm, 0, 4, 3, 0.45)
        c.paint(OUTLINE, dilate(tm, 3.5))
        c.paint(vgrad(c, [(0, darken(red, 0.12)), (1, red_lo)], 46, 112), tm)
        emboss(c, tm, 2.5, 0.3, 0.3)
        fm = m_poly(c, fold)
        c.paint(OUTLINE, dilate(fm, 2))
        c.paint(darken(red_lo, 0.35), fm)
    band = m_rrect(c, 60, 18, 452, 98, 10)
    drop_shadow(c, band, 0, 5, 4, 0.5)
    c.paint(OUTLINE, dilate(band, 4))
    c.paint(vgrad(c, [(0, red_hi), (0.45, red), (1, darken(red, 0.25))], 18, 98), band)
    emboss(c, band, 3.5, 0.4, 0.35)
    # gold trims
    for ty in (26, 88):
        tm = m_rrect(c, 66, ty - 2.2, 446, ty + 2.2, 2)
        c.paint(vgrad(c, [(0, GOLD_HI), (1, GOLD_DEEP)], ty - 2.2, ty + 2.2), tm)
        c.tint(SHADOW, shift(tm, 0, 1.5) * sub(band, tm), 0.25)
    hl = m_rrect(c, 70, 30, 442, 52, 8)
    c.tint(WHITE, hl * np.clip(1 - (c.Y - 30) / 22, 0, 1), 0.3)
    # soft vertical curl shading near the ends
    curl = np.clip(1 - (np.minimum(c.X - 60, 452 - c.X)) / 26, 0, 1) * band
    c.tint(SHADOW, curl, 0.3)
    center = (124, 34, 388, 82)
    save("ui_ribbon", c, "ribbon", slice_rec((W, H), center, (10, 14, 10, 12), 0.45))


def make_bar():
    W, H = 256, 64
    c = Canvas(W, H)
    x0, y0, x1, y1 = 6, 6, 250, 54
    R = 24
    outer = m_rrect(c, x0, y0, x1, y1, R)
    drop_shadow(c, outer, 0, 3, 2.5, 0.45)
    c.paint(OUTLINE, outer)
    rim = m_rrect(c, x0 + 3, y0 + 3, x1 - 3, y1 - 3, R - 3)
    c.paint(np.where((c.Y < 30)[..., None], wood(c, "h", 5), wood(c, "h", 6)), rim)
    emboss(c, rim, 2.5, 0.5, 0.4)
    groove = m_rrect(c, x0 + 8, y0 + 8, x1 - 8, y1 - 8, R - 8)
    c.paint(OUTLINE, dilate(groove, 1.2))
    c.paint(vgrad(c, [(0, (30, 18, 10)), (1, (62, 40, 24))], y0 + 8, y1 - 8), groove)
    inner_shadow(c, groove, 3, 0, 2, (0, 0, 0), 0.6)
    save("ui_bar_frame", c, "bars", slice_rec((W, H), (x0 + R + 6, 28, x1 - R - 6, 34), (x0, y0, W - x1, H - y1), 0.45, inset=[8, 8, 8, 8]))
    # fill: white glossy capsule (ImageColor3 = the bar colour)
    c = Canvas(W, H)
    x0, y0, x1, y1 = 4, 8, 252, 56
    R = 24
    body = m_rrect(c, x0, y0, x1, y1, R)
    c.paint(vgrad(c, [(0, (255, 255, 255)), (0.5, (236, 236, 236)), (1, (160, 160, 160))], y0, y1), body)
    emboss(c, body, 3, 0.35, 0.35)
    hl = m_rrect(c, x0 + 10, y0 + 4, x1 - 10, y0 + 18, 7)
    c.tint(WHITE, hl, 0.55)
    # diagonal stripes, subtle
    stripes = (np.sin((c.X + c.Y) * 0.22) > 0.55).astype(F32) * body
    c.tint(WHITE, blur(stripes, 0.4), 0.12)
    save("ui_bar_fill", c, "bars", slice_rec((W, H), (x0 + R + 4, 28, x1 - R - 4, 36), (x0, y0, W - x1, H - y1), 0.45))


def make_close():
    W = H = 128
    for state in ("normal", "hover", "pressed"):
        c = Canvas(W, H)
        cx, cy, r = 64, 60, 50
        press = 4 if state == "pressed" else 0
        outer = m_ellipse(c, cx, cy + press / 2, r, r - press / 2)
        drop_shadow(c, outer, 0, 2 if press else 6, 3 if press else 5, 0.5)
        if state == "hover":
            glow(c, outer, 5, (255, 170, 150), 0.6)
        c.paint(OUTLINE, outer)
        lip = m_ellipse(c, cx, cy + press / 2, r - 4, r - 4 - press / 2)
        c.paint((140, 26, 22), lip)
        face = m_ellipse(c, cx, cy - 3 + press, r - 4, r - 8)
        top, bot = (255, 128, 110), (210, 50, 40)
        if state == "hover":
            top, bot = lighten(top, 0.15), lighten(bot, 0.12)
        if state == "pressed":
            top, bot = darken(top, 0.06), darken(bot, 0.1)
        c.paint(vgrad(c, [(0, top), (1, bot)], cy - r, cy + r), face)
        emboss(c, face, 3.5, 0.4, 0.3)
        hl = m_ellipse(c, cx - 4, cy - 26 + press, 30, 14)
        c.tint(WHITE, hl * np.clip(1 - (c.Y - (cy - 40 + press)) / 28, 0, 1), 0.55)
        x = union(m_rot_rect(c, cx, cy - 2 + press, 56, 15, 45, 3), m_rot_rect(c, cx, cy - 2 + press, 56, 15, -45, 3))
        drop_shadow(c, x, 0, 2, 1.2, 0.4)
        c.paint(OUTLINE, dilate(x, 3))
        c.paint(vgrad(c, [(0, WHITE), (1, (255, 226, 214))], cy - 30, cy + 30), x)
        emboss(c, x, 2, 0.3, 0.25)
        save("ui_close" + ("" if state == "normal" else f"_{state}"), c, "misc", None)


def make_dot():
    W = H = 64
    c = Canvas(W, H)
    m = m_ellipse(c, 32, 30, 22)
    glow(c, m, 4, (255, 120, 80), 0.5)
    drop_shadow(c, m, 0, 3, 2, 0.5)
    c.paint(OUTLINE, m)
    c.paint(WHITE, m_ellipse(c, 32, 30, 20))
    core = m_ellipse(c, 32, 30, 15.5)
    c.paint(radial(c, 27, 24, 24, [(0, (255, 170, 130)), (0.55, (236, 64, 48)), (1, (150, 24, 18))]), core)
    c.paint(WHITE, m_ellipse(c, 27, 23, 6, 4), 0.85)
    save("ui_dot", c, "misc", None)


def make_pattern():
    W = H = 256
    c = Canvas(W, H)
    rng = np.random.default_rng(1234)
    holes = []
    tries = 0
    while len(holes) < 13 and tries < 2000:
        tries += 1
        r = float(rng.uniform(9, 24))
        x, y = float(rng.uniform(0, W)), float(rng.uniform(0, H))
        ok = True
        for (hx, hy, hr) in holes:
            ddx = min(abs(x - hx), W - abs(x - hx))
            ddy = min(abs(y - hy), H - abs(y - hy))
            if math.hypot(ddx, ddy) < r + hr + 14:
                ok = False
                break
        if ok:
            holes.append((x, y, r))
    m_all = np.zeros((c.H, c.W), F32)
    for (x, y, r) in holes:
        for ox in (-W, 0, W):
            for oy in (-H, 0, H):
                m_all = np.maximum(m_all, m_ellipse(c, x + ox, y + oy, r, r * 0.86))
    # a hole: darker cheese with shading (top inside dark, bottom rim light)
    c.paint((214, 150, 44), m_all, 0.9)
    inv = 1 - m_all
    top_shadow = np.clip(shift(blur(inv, 3), 0, 3) * m_all, 0, 1)
    c.tint((150, 92, 20), top_shadow, 0.8)
    lip = sub(dilate(m_all, 1.6), m_all)
    c.paint((255, 236, 170), shift(lip, 0.6, 1.2) * (1 - m_all), 0.65)
    save("ui_pattern_cheese", c, "patterns", None)


def make_wood_strip():
    W, H = 512, 64
    c = Canvas(W, H)
    full = np.ones((c.H, c.W), F32)
    n1 = value_noise(c, 64, 10, 91, wrap_x=True)
    n2 = value_noise(c, 128, 3, 92, wrap_x=True)
    period = 2 * math.pi / W
    t = c.Y * 0.55 + n1 * 7 + np.sin(c.X * period * 3 + n1 * 3) * 1.4
    g = (0.5 + 0.5 * np.sin(t)) ** 2.2
    k = np.clip(g * 0.75 + 0.15 + (n2 - 0.5) * 0.55, 0, 1)[..., None]
    col = rgb((132, 82, 42)) * (1 - k) + rgb((204, 144, 84)) * k
    c.paint(col, full)
    c.tint(WHITE, np.clip(1 - c.Y / 6, 0, 1), 0.35)
    c.tint(SHADOW, np.clip((c.Y - (H - 8)) / 8, 0, 1), 0.55)
    c.tint(OUTLINE, (c.Y < 1.5).astype(F32), 0.9)
    c.tint(OUTLINE, (c.Y > H - 1.5).astype(F32), 0.9)
    save("ui_wood_strip", c, "patterns", None)


# ---------------------------------------------------------------- icons


def icon_canvas():
    return Canvas(128, 128)


def outlined(c, mask, width=4.0, shadow=True):
    if shadow:
        drop_shadow(c, dilate(mask, width), 0, 3, 2.5, 0.45)
    c.paint(OUTLINE, dilate(mask, width))


def part(c, mask, top, bottom, y0, y1, bevel=3.0, hi=0.45, lo=0.3):
    c.paint(vgrad(c, [(0, top), (1, bottom)], y0, y1), mask)
    if bevel:
        emboss(c, mask, bevel, hi, lo)


def spec(c, x, y, rx, ry, op=0.8):
    c.paint(WHITE, m_ellipse(c, x, y, rx, ry), op)


def cheese_wedge(c, gold=False):
    top_pts = [(10, 70), (78, 26), (118, 44), (50, 84)]
    front_pts = [(10, 70), (50, 84), (50, 112), (10, 98)]
    side_pts = [(50, 84), (118, 44), (118, 80), (50, 112)]
    top = m_poly(c, top_pts)
    front = m_poly(c, front_pts)
    side = m_poly(c, side_pts)
    allm = union(top, front, side)
    outlined(c, allm)
    if gold:
        tcol, scol, fcol = ((255, 246, 170), (255, 214, 70)), ((255, 196, 40), (214, 132, 10)), ((240, 170, 30), (196, 112, 8))
    else:
        tcol, scol, fcol = ((255, 236, 140), (255, 210, 80)), ((252, 190, 50), (226, 146, 24)), ((236, 160, 40), (206, 124, 20))
    part(c, top, tcol[0], tcol[1], 26, 84, 2.5, 0.4, 0.15)
    part(c, side, scol[0], scol[1], 44, 112, 2.5, 0.25, 0.25)
    part(c, front, fcol[0], fcol[1], 70, 112, 2.5, 0.2, 0.3)
    # rind on the far edge
    rind = inter(m_poly(c, [(110, 49), (118, 44), (118, 80), (110, 85)]), side)
    c.tint((226, 116, 30) if not gold else (230, 140, 10), rind, 0.75)
    # edges between faces
    for m in (top, side):
        e = sub(dilate(m, 0.7), m) * allm
        c.tint(OUTLINE, e, 0.35)
    # holes
    for (hx, hy, rx, ry, face) in ((72, 72, 9, 7, side), (98, 66, 6, 5, side), (90, 92, 7, 6, side), (30, 90, 6, 5.5, front), (62, 50, 8, 4, top), (88, 42, 5, 2.6, top)):
        hm = inter(m_ellipse(c, hx, hy, rx, ry), face)
        c.tint((196, 116, 14) if not gold else (204, 120, 0), hm, 0.9)
        inner_shadow(c, hm, 1.8, 0, 1.6, (120, 64, 0), 0.7)
        rim = sub(shift(hm, 0.8, 1.2), hm) * face
        c.tint(WHITE, rim, 0.45)
    c.tint(WHITE, sub(top, shift(top, 0, 1.6)), 0.5)
    if gold:
        sparkle(c, 30, 40, 13)
        sparkle(c, 104, 20, 9)
        sparkle(c, 112, 100, 7, 0.9)


def icon_cheese():
    c = icon_canvas()
    cheese_wedge(c)
    return c


def icon_golden_cheese():
    c = icon_canvas()
    glow(c, m_ellipse(c, 64, 70, 46, 36), 10, (255, 220, 90), 0.55)
    cheese_wedge(c, gold=True)
    return c


def icon_coin():
    c = icon_canvas()
    m = m_ellipse(c, 64, 62, 52)
    outlined(c, m, 3.5)
    edge = m_ellipse(c, 64, 66, 50, 48)
    c.paint((176, 104, 12), m)
    face = m_ellipse(c, 64, 60, 49, 47)
    part(c, face, (255, 240, 150), (232, 156, 20), 12, 108, 4, 0.5, 0.3)
    ring = sub(m_ellipse(c, 64, 60, 39), m_ellipse(c, 64, 60, 35))
    c.tint((176, 104, 12), ring, 0.75)
    c.tint(WHITE, shift(ring, 1, 1.2) * (1 - ring), 0.4)
    # emerald hexagon gem in the middle (generic premium coin, not any brand mark)
    gem(c, 64, 60, 24, (60, 200, 100), sides=6, rot=30)
    spec(c, 40, 30, 12, 6, 0.6)
    return c


def icon_boost():
    c = icon_canvas()
    pts = [(74, 4), (24, 72), (58, 72), (44, 124), (104, 48), (70, 48), (90, 4)]
    m = roundify(m_poly(c, pts), 2.5)
    glow(c, m, 9, (255, 214, 60), 0.65)
    outlined(c, m, 4)
    part(c, m, (255, 248, 170), (255, 136, 20), 4, 124, 3.5, 0.5, 0.3)
    c.tint(WHITE, inter(m_poly(c, [(74, 8), (34, 68), (48, 68), (82, 10)]), m), 0.35)
    return c


def icon_pass():
    c = icon_canvas()
    body = m_rrect(c, 8, 30, 120, 100, 10)
    for nx in (8, 120):
        body = sub(body, m_ellipse(c, nx, 65, 10))
    stub = inter(body, (c.X > 88).astype(F32))
    main = sub(body, stub)
    c2 = body
    outlined(c, c2, 3.5)
    part(c, main, (255, 236, 140), (240, 170, 34), 30, 100, 3, 0.45, 0.3)
    part(c, stub, (255, 140, 110), (206, 56, 44), 30, 100, 3, 0.4, 0.3)
    perf = np.zeros_like(body)
    for py in range(36, 98, 8):
        perf = np.maximum(perf, m_ellipse(c, 88, py, 1.8))
    c.tint(OUTLINE, perf * body, 0.8)
    st = star_mask(c, 48, 66, 22, 9.5)
    c.paint(OUTLINE, dilate(st, 2.2))
    part(c, st, (255, 255, 230), (255, 196, 60), 44, 88, 1.8, 0.4, 0.3)
    hl = m_rrect(c, 14, 34, 84, 50, 6)
    c.tint(WHITE, hl * main, 0.35)
    return c


def star_mask(c, cx, cy, ro, ri, rot=-90):
    pts = []
    for i in range(10):
        a = math.radians(rot + i * 36)
        r = ro if i % 2 == 0 else ri
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return m_poly(c, pts)


def icon_star():
    c = icon_canvas()
    m = roundify(star_mask(c, 64, 68, 58, 25), 3)
    glow(c, m, 7, (255, 220, 100), 0.35)
    outlined(c, m, 4)
    part(c, m, (255, 248, 170), (238, 150, 14), 10, 124, 4, 0.5, 0.35)
    # facet split: right halves of each point darker
    for i in range(5):
        a = math.radians(-90 + i * 72)
        tip = (64 + 58 * math.cos(a), 68 + 58 * math.sin(a))
        a2 = math.radians(-90 + i * 72 + 36)
        valley = (64 + 25 * math.cos(a2), 68 + 25 * math.sin(a2))
        fm = m_poly(c, [(64, 68), tip, valley])
        c.tint(SHADOW, fm * m, 0.16)
    spec(c, 48, 46, 9, 5, 0.7)
    return c


def icon_lock():
    c = icon_canvas()
    shackle = union(m_arc(c, 64, 46, 30, 180, 360, 13), m_rrect(c, 34, 44, 47, 66, 2), m_rrect(c, 81, 44, 94, 66, 2))
    body = m_rrect(c, 20, 58, 108, 120, 14)
    outlined(c, union(shackle, body), 4)
    part(c, shackle, (240, 244, 250), (130, 140, 156), 14, 66, 3, 0.55, 0.35)
    part(c, body, (255, 232, 120), (214, 136, 16), 58, 120, 4, 0.5, 0.35)
    kh = union(m_ellipse(c, 64, 82, 9), m_poly(c, [(58, 84), (70, 84), (74, 106), (54, 106)]))
    c.paint(OUTLINE, kh)
    c.tint(WHITE, sub(shift(kh, 0, 1.5), kh) * body, 0.4)
    hl = m_rrect(c, 28, 63, 100, 78, 8)
    c.tint(WHITE, hl * body, 0.35)
    return c


def icon_check():
    c = icon_canvas()
    m = roundify(m_poly(c, [(8, 70), (32, 46), (52, 66), (96, 14), (122, 38), (52, 112)]), 4)
    outlined(c, m, 4.5)
    part(c, m, (176, 246, 130), (44, 150, 56), 14, 112, 4, 0.5, 0.35)
    spec(c, 100, 26, 8, 4, 0.6)
    return c


def icon_gift():
    c = icon_canvas()
    box = m_rrect(c, 18, 60, 110, 120, 6)
    lid = m_rrect(c, 10, 42, 118, 64, 6)
    bowl = m_ellipse(c, 44, 30, 20, 13)
    bowr = m_ellipse(c, 84, 30, 20, 13)
    knot = m_ellipse(c, 64, 38, 10, 9)
    allm = union(box, lid, bowl, bowr, knot)
    outlined(c, allm, 4)
    part(c, bowl, (255, 240, 150), (220, 150, 20), 17, 43, 2.5)
    part(c, bowr, (255, 240, 150), (220, 150, 20), 17, 43, 2.5)
    for (bx, by) in ((44, 31), (84, 31)):
        c.tint((150, 90, 10), m_ellipse(c, bx, by, 9, 5) * union(bowl, bowr), 0.55)
    part(c, box, (238, 84, 66), (170, 34, 30), 60, 120, 3)
    part(c, lid, (255, 120, 100), (206, 56, 44), 42, 64, 3)
    band = inter(m_rrect(c, 55, 40, 73, 122, 2), union(box, lid))
    part(c, band, (255, 240, 150), (214, 140, 16), 40, 122, 2, 0.4, 0.25)
    c.tint(SHADOW, inter(sub(box, shift(lid, 0, 4)), (c.Y < 70).astype(F32)) * box, 0.25)
    part(c, knot, (255, 236, 140), (214, 140, 16), 29, 47, 2)
    c.paint(OUTLINE, sub(dilate(knot, 1.2), knot) * union(bowl, bowr, lid), 0.9)
    return c


def icon_trophy():
    c = icon_canvas()
    cup = roundify(m_poly(c, [(26, 14), (102, 14), (98, 52), (82, 72), (46, 72), (30, 52)]), 4)
    hl_ = m_arc(c, 28, 38, 17, 90, 270, 8)
    hr_ = m_arc(c, 100, 38, 17, 270, 90, 8)
    stem = m_rrect(c, 56, 68, 72, 92, 3)
    base1 = m_rrect(c, 38, 88, 90, 102, 4)
    base2 = m_rrect(c, 28, 100, 100, 118, 5)
    allm = union(cup, hl_, hr_, stem, base1, base2)
    outlined(c, allm, 4)
    gold = ((255, 242, 160), (220, 140, 14))
    for m, y0, y1 in ((hl_, 20, 56), (hr_, 20, 56), (stem, 68, 92), (base1, 88, 102)):
        part(c, m, gold[0], gold[1], y0, y1, 2.5)
    part(c, base2, (150, 96, 56), (96, 58, 30), 100, 118, 2.5)
    part(c, cup, gold[0], gold[1], 14, 72, 4, 0.5, 0.35)
    rim = m_ellipse(c, 64, 16, 37, 5)
    c.tint((176, 104, 12), inter(rim, cup), 0.6)
    st = star_mask(c, 64, 40, 14, 6)
    c.paint((176, 104, 12), dilate(st, 1.2), 0.8)
    c.paint((255, 252, 220), st)
    spec(c, 42, 30, 6, 10, 0.55)
    return c


def icon_scroll():
    c = icon_canvas()
    sheet = m_rrect(c, 26, 20, 102, 108, 3)
    top = m_rrect(c, 14, 10, 114, 32, 11)
    bot = m_rrect(c, 14, 96, 114, 118, 11)
    allm = union(sheet, top, bot)
    outlined(c, allm, 4)
    part(c, sheet, (255, 246, 220), (232, 206, 156), 20, 108, 2.5, 0.3, 0.2)
    for m, y0, y1 in ((top, 10, 32), (bot, 96, 118)):
        part(c, m, (250, 230, 180), (196, 156, 96), y0, y1, 3, 0.5, 0.35)
        ends = union(m_ellipse(c, 16, (y0 + y1) / 2, 6, 9), m_ellipse(c, 112, (y0 + y1) / 2, 6, 9))
        c.tint((170, 120, 60), inter(ends, m), 0.6)
    for i, ly in enumerate((44, 56, 68, 80)):
        w = 56 if i < 3 else 36
        c.paint((150, 104, 60), m_rrect(c, 36, ly - 1.6, 36 + w, ly + 1.6, 1.6), 0.8)
    seal = m_ellipse(c, 86, 84, 12)
    c.paint(OUTLINE, dilate(seal, 1.5))
    part(c, seal, (240, 90, 76), (160, 30, 26), 72, 96, 2.5)
    c.tint((120, 20, 18), m_ellipse(c, 86, 84, 6) - m_ellipse(c, 86, 84, 4), 0.6)
    return c


def icon_book():
    c = icon_canvas()
    pages = m_rrect(c, 28, 20, 112, 116, 6)
    cover = m_rrect(c, 16, 12, 104, 110, 8)
    allm = union(pages, cover)
    outlined(c, allm, 4)
    part(c, pages, (255, 250, 236), (220, 206, 176), 20, 116, 1.5, 0.2, 0.2)
    for py in range(28, 112, 6):
        c.tint((190, 170, 140), inter(m_rrect(c, 100, py, 112, py + 1, 0), pages), 0.6)
    part(c, cover, (90, 150, 220), (40, 80, 160), 12, 110, 3.5, 0.45, 0.35)
    spine = inter(m_rrect(c, 16, 12, 32, 110, 0), cover)
    c.tint((24, 50, 110), spine, 0.55)
    c.tint(WHITE, sub(spine, shift(spine, -1.5, 0)) * cover, 0.3)
    # gold corner caps
    for (cx_, cy_) in ((104, 12), (104, 110)):
        cap = inter(m_poly(c, [(cx_ - 14, cy_), (cx_, cy_), (cx_, cy_ + (14 if cy_ < 60 else -14))]), cover)
        c.tint(GOLD, cap, 0.95)
    # emblem: a gold medallion with a mouse silhouette (Mousepedia)
    med = m_ellipse(c, 64, 60, 22)
    c.paint(OUTLINE, dilate(med, 2))
    part(c, med, (255, 240, 150), (210, 136, 14), 38, 82, 2.5)
    mouse = union(m_ellipse(c, 64, 64, 11, 10), m_ellipse(c, 53, 52, 6.5), m_ellipse(c, 75, 52, 6.5))
    c.paint((120, 72, 30), mouse, 0.9)
    return c


def elephant_head(c, cx=64, cy=62, s=1.0, grey=((196, 204, 214), (128, 138, 152))):
    def S(v):
        return v * s

    earl = m_ellipse(c, cx - S(38), cy - S(2), S(28), S(34))
    earr = m_ellipse(c, cx + S(38), cy - S(2), S(28), S(34))
    head = m_ellipse(c, cx, cy - S(6), S(32), S(34))
    trunk = m_line(c, [(cx, cy + S(10)), (cx - S(2), cy + S(30)), (cx + S(6), cy + S(46)), (cx + S(18), cy + S(50))], S(17))
    allm = union(earl, earr, head, trunk)
    outlined(c, allm, 4 * s)
    for ear, sx in ((earl, -1), (earr, 1)):
        part(c, ear, grey[0], grey[1], cy - S(36), cy + S(32), 3)
        inner = inter(m_ellipse(c, cx + sx * S(40), cy, S(17), S(23)), ear)
        c.tint(PINK, inner, 0.85)
        inner_shadow(c, inner, 2.5, 0, 2, (160, 80, 100), 0.4)
    part(c, trunk, grey[0], grey[1], cy, cy + S(58), 3)
    for k in range(3):
        wy = cy + S(24 + k * 7)
        c.tint(grey[1], inter(m_rrect(c, cx - S(9), wy, cx + S(7), wy + S(1.6), S(1)), trunk), 0.7)
    part(c, head, grey[0], grey[1], cy - S(40), cy + S(28), 4, 0.5, 0.3)
    c.paint(OUTLINE, sub(dilate(head, 1.2 * s), head) * trunk, 0.0)
    # tusks
    for sx in (-1, 1):
        t = m_poly(c, [(cx + sx * S(12), cy + S(14)), (cx + sx * S(20), cy + S(16)), (cx + sx * S(24), cy + S(30))])
        t = roundify(t, 1.5)
        c.paint(OUTLINE, dilate(t, 1.6 * s))
        c.paint((255, 250, 236), t)
    # eyes + cheeks
    for sx in (-1, 1):
        e = m_ellipse(c, cx + sx * S(13), cy - S(10), S(5.5), S(7.5))
        c.paint(OUTLINE, e)
        spec(c, cx + sx * S(13) - S(1.8), cy - S(13), S(2), S(2.4), 1.0)
        c.paint(PINK, m_ellipse(c, cx + sx * S(21), cy + S(4), S(6), S(3.5)), 0.6)
    spec(c, cx - S(12), cy - S(30), S(9), S(4), 0.35)


def icon_elephant():
    c = icon_canvas()
    elephant_head(c, 64, 60, 0.95)
    return c


def icon_mouse():
    c = icon_canvas()
    brown = ((176, 136, 100), (120, 84, 54))
    earl = m_ellipse(c, 32, 34, 25)
    earr = m_ellipse(c, 96, 34, 25)
    head = m_ellipse(c, 64, 74, 40, 38)
    allm = union(earl, earr, head)
    outlined(c, allm, 4)
    for ear, ex in ((earl, 32), (earr, 96)):
        part(c, ear, brown[0], brown[1], 9, 59, 3)
        inner = inter(m_ellipse(c, ex, 36, 15), ear)
        c.tint(PINK, inner, 0.9)
        inner_shadow(c, inner, 2.5, 0, 2, (160, 80, 100), 0.4)
    part(c, head, brown[0], brown[1], 36, 112, 4, 0.5, 0.3)
    snout = m_ellipse(c, 64, 92, 22, 15)
    c.tint((226, 200, 170), snout, 0.9)
    emboss(c, snout, 2, 0.3, 0.15)
    nose = m_ellipse(c, 64, 84, 7.5, 6)
    c.paint(OUTLINE, dilate(nose, 1.2))
    c.paint((240, 130, 150), nose)
    spec(c, 62, 82, 2.5, 1.6, 0.9)
    tooth = m_rrect(c, 60, 98, 68, 106, 1.5)
    c.paint(OUTLINE, dilate(tooth, 1.2))
    c.paint(WHITE, tooth)
    for sx in (-1, 1):
        e = m_ellipse(c, 64 + sx * 15, 68, 5.5, 7.5)
        c.paint(OUTLINE, e)
        spec(c, 64 + sx * 15 - 1.8, 65, 2, 2.4, 1.0)
        for wy, dy2 in ((88, -4), (94, 2)):
            c.paint(OUTLINE, m_line(c, [(64 + sx * 26, wy), (64 + sx * 46, wy + dy2)], 1.6), 0.8)
    spec(c, 50, 48, 10, 5, 0.3)
    return c


def shield_mask(c):
    pts = [(14, 10), (114, 10), (114, 58)]
    for i in range(1, 12):
        t = i / 12
        pts.append((114 - 50 * t, 58 + 62 * math.sin(t * math.pi / 2)))
    pts.append((64, 122))
    for i in range(11, 0, -1):
        t = i / 12
        pts.append((14 + 50 * t, 58 + 62 * math.sin(t * math.pi / 2)))
    pts.append((14, 58))
    return roundify(m_poly(c, pts), 4)


def emblem(color, draw_symbol):
    c = icon_canvas()
    sh = shield_mask(c)
    outlined(c, sh, 3.5)
    c.paint(vgrad(c, [(0, GOLD_HI), (0.5, GOLD), (1, GOLD_DEEP)], 10, 122), sh)
    emboss(c, sh, 2.5, 0.5, 0.35)
    inner = erode(sh, 7)
    c.paint(OUTLINE, sub(dilate(inner, 1.4), inner) * sh, 0.9)
    part(c, inner, lighten(color, 0.3), darken(color, 0.3), 16, 116, 3.5, 0.35, 0.3)
    # diagonal sheen
    sheen = inter(m_poly(c, [(20, 16), (60, 16), (20, 64)]), inner)
    c.tint(WHITE, sheen, 0.18)
    sym = draw_symbol(c)
    if sym is not None:
        drop_shadow(c, dilate(sym, 3), 0, 2.5, 2, 0.4)
        c.paint(OUTLINE, dilate(sym, 3))
        part(c, sym, (255, 255, 246), (232, 216, 186), 24, 104, 2.5, 0.4, 0.3)
    return c


def sym_fist(c):
    glove = m_ellipse(c, 64, 52, 26, 24)
    thumb = m_ellipse(c, 44, 66, 11, 13)
    cuff = m_rrect(c, 46, 70, 82, 96, 5)
    m = union(glove, thumb, cuff)
    return m


def sym_drop(c):
    return union(m_ellipse(c, 64, 74, 24), m_poly(c, [(64, 22), (85, 64), (43, 64)]))


def sym_bow(c):
    bow = m_arc(c, 76, 62, 38, 120, 240, 8)
    string = m_line(c, [(57, 29), (57, 95)], 2.5, caps=False)
    arrow = m_line(c, [(36, 62), (92, 62)], 5)
    head = m_poly(c, [(90, 52), (106, 62), (90, 72)])
    fl = m_poly(c, [(34, 62), (28, 54), (40, 54), (46, 62), (40, 70), (28, 70)])
    return union(bow, string, arrow, head, fl)


def sym_rapier(c):
    blade = m_rot_rect(c, 70, 54, 9, 76, 45, 0)
    tip = m_poly(c, [(92, 26), (100, 22), (96, 32)])
    guard = m_arc(c, 46, 78, 14, 200, 380, 6)
    cross = m_rot_rect(c, 48, 76, 34, 7, -45, 2)
    grip = m_rot_rect(c, 38, 88, 8, 22, 45, 2)
    pommel = m_ellipse(c, 31, 95, 6)
    return union(blade, tip, guard, cross, grip, pommel)


def sym_chef(c):
    puff = union(m_ellipse(c, 44, 50, 16), m_ellipse(c, 64, 40, 19), m_ellipse(c, 84, 50, 16), m_rrect(c, 40, 50, 88, 76, 4))
    band = m_rrect(c, 42, 74, 86, 92, 4)
    return union(puff, band)


def sym_wing(c):
    fs = []
    for i, (cx, cy, rx, ry, rot) in enumerate(((60, 44, 34, 11, -20), (58, 62, 30, 10, -10), (56, 78, 24, 9, 0), (54, 92, 17, 8, 10))):
        fs.append(m_rot_rect(c, cx, cy, rx * 2, ry * 2, rot, 8))
    root = m_ellipse(c, 36, 64, 12, 30)
    return union(root, *fs)


def sym_flask(c):
    bulb = m_ellipse(c, 64, 76, 26)
    neck = m_rrect(c, 55, 30, 73, 60, 3)
    cork = m_rrect(c, 52, 22, 76, 34, 4)
    return union(bulb, neck, cork)


def flask_details(c):
    liquid = inter(m_ellipse(c, 64, 76, 21), (c.Y > 70).astype(F32))
    c.paint((120, 230, 140), liquid, 0.9)
    emboss(c, liquid, 2, 0.4, 0.2)
    for (bx, by, br) in ((56, 86, 3.5), (70, 80, 2.5), (64, 92, 2)):
        c.paint(WHITE, m_ellipse(c, bx, by, br), 0.8)
    c.tint((160, 110, 60), m_rrect(c, 52, 22, 76, 34, 4), 0.85)


CLASS_EMBLEMS = {
    "elephante": ((214, 70, 58), sym_fist, None),
    "ele_fonte": ((56, 136, 230), sym_drop, None),
    "ellie_fawn": ((76, 170, 80), sym_bow, None),
    "le_fante": ((150, 88, 214), sym_rapier, None),
    "filet": ((240, 140, 46), sym_chef, None),
    "jumbo": ((84, 176, 232), sym_wing, None),
    "fizzante": ((36, 166, 156), sym_flask, flask_details),
}


def make_icons():
    simple = {
        "cheese": icon_cheese,
        "golden_cheese": icon_golden_cheese,
        "coin": icon_coin,
        "boost": icon_boost,
        "pass": icon_pass,
        "star": icon_star,
        "lock": icon_lock,
        "check": icon_check,
        "gift": icon_gift,
        "trophy": icon_trophy,
        "scroll": icon_scroll,
        "book": icon_book,
        "elephant": icon_elephant,
        "mouse": icon_mouse,
    }
    for name, fn in simple.items():
        save(f"ui_icon_{name}", fn(), "icons", None)
    for cid, (color, sym, extra) in CLASS_EMBLEMS.items():
        c = emblem(color, sym)
        if extra:
            extra(c)
        save(f"ui_class_{cid}", c, "emblems", None)


# ---------------------------------------------------------------- outputs


def build_all():
    make_panel("ui_panel", dark=False)
    make_panel("ui_panel_dark", dark=True)
    make_buttons()
    make_tabs()
    make_cards()
    make_price_tag()
    make_badge()
    make_ribbon()
    make_bar()
    make_close()
    make_dot()
    make_pattern()
    make_wood_strip()
    make_icons()


def is_pow2(n):
    return n > 0 and (n & (n - 1)) == 0


def write_outputs():
    os.makedirs(OUT_DIR, exist_ok=True)
    keep = set()
    slices = {}
    for name, t in sorted(TEXTURES.items()):
        img = t["img"]
        w, h = img.size
        assert is_pow2(w) and is_pow2(h) and max(w, h) <= 1024, f"{name}: {w}x{h}"
        path = os.path.join(OUT_DIR, name + ".png")
        img.save(path, optimize=True)
        keep.add(name + ".png")
        if t["slice"]:
            slices[name] = t["slice"]
    for f in os.listdir(OUT_DIR):
        if f.endswith(".png") and f not in keep:
            os.remove(os.path.join(OUT_DIR, f))
    with open(SLICES_JSON, "w", encoding="utf-8") as fh:
        json.dump(slices, fh, indent=1, sort_keys=True)
        fh.write("\n")
    write_luau(slices)
    write_manifest()
    print(f"{len(TEXTURES)} textures -> {os.path.relpath(OUT_DIR, ROOT)} ({len(slices)} 9-slice)")


def _num(v):
    return str(int(v)) if float(v).is_integer() else repr(round(float(v), 4))


def write_luau(slices):
    lines = [
        "--!strict",
        "-- GENERATED by scripts/make-ui-textures.py from assets/ui/slices.json. Don't edit.",
        "-- 9-slice data of the UI textures (UI/Skin): size, SliceCenter rect, transparent",
        "-- pad around the visible frame, preferred SliceScale and (bars) the fill inset.",
        "",
        "export type Slice = {",
        "\tsize: { number },",
        "\tcenter: { number },",
        "\tpad: { number },",
        "\tscale: number,",
        "\tinset: { number }?,",
        "}",
        "",
        "local SLICES: { [string]: Slice } = {",
    ]
    for name in sorted(slices):
        s = slices[name]
        parts = [
            f"size = {{ {', '.join(_num(v) for v in s['size'])} }}",
            f"center = {{ {', '.join(_num(v) for v in s['center'])} }}",
            f"pad = {{ {', '.join(_num(v) for v in s['pad'])} }}",
            f"scale = {_num(s['scale'])}",
        ]
        if "inset" in s:
            parts.append(f"inset = {{ {', '.join(_num(v) for v in s['inset'])} }}")
        lines.append(f"\t{name} = {{")
        for p in parts:
            lines.append(f"\t\t{p},")
        lines.append("\t},")
    lines += ["}", "", "-- Every texture name the skin may use (9-slice or not).", "local NAMES: { string } = {"]
    for name in sorted(TEXTURES):
        lines.append(f'\t"{name}",')
    lines += ["}", "", "return { slices = SLICES, names = NAMES }", ""]
    with open(SLICES_LUAU, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))


def write_manifest():
    """Adds / refreshes the ui_* Image entries in assets/models/manifest.json."""
    entries = []
    wrapped = False
    if os.path.exists(MANIFEST):
        data = json.load(open(MANIFEST, encoding="utf-8"))
        wrapped = isinstance(data, dict)
        entries = data.get("assets", []) if wrapped else data
    others = [e for e in entries if not str(e.get("name", "")).startswith("ui_")]
    ui = []
    for name in sorted(TEXTURES):
        ui.append(
            {
                "name": name,
                "path": f"../ui/{name}.png",
                "type": "Image",
                "description": f"Trunkfall UI texture: {name}",
            }
        )
    out = others + ui
    data = {"assets": out} if wrapped else out
    with open(MANIFEST, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")


# ---------------------------------------------------------------- previews (not shipped)


def nine_slice(img, info, w, h, scale):
    """Renders a texture 9-sliced to the visible size w x h (like Roblox, incl. pad)."""
    tw, th = img.size
    x0, y0, x1, y1 = info["center"]
    pl, pt, pr, pb = info["pad"]
    W = int(round(w + (pl + pr) * scale))
    H = int(round(h + (pt + pb) * scale))
    L, T, Rr, B = x0 * scale, y0 * scale, (tw - x1) * scale, (th - y1) * scale
    k = min(1.0, W / max(1e-6, L + Rr), H / max(1e-6, T + B))
    L, T, Rr, B = L * k, T * k, Rr * k, B * k
    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    xs_src = [0, x0, x1, tw]
    ys_src = [0, y0, y1, th]
    xs_dst = [0, L, W - Rr, W]
    ys_dst = [0, T, H - B, H]
    for i in range(3):
        for j in range(3):
            sx0, sx1 = xs_src[i], xs_src[i + 1]
            sy0, sy1 = ys_src[j], ys_src[j + 1]
            dx0, dx1 = int(round(xs_dst[i])), int(round(xs_dst[i + 1]))
            dy0, dy1 = int(round(ys_dst[j])), int(round(ys_dst[j + 1]))
            if dx1 <= dx0 or dy1 <= dy0 or sx1 <= sx0 or sy1 <= sy0:
                continue
            piece = img.crop((sx0, sy0, sx1, sy1)).resize((dx1 - dx0, dy1 - dy0), Image.LANCZOS)
            out.alpha_composite(piece, (dx0, dy0))
    return out, (int(round(pl * scale * k)), int(round(pt * scale * k)))


def tinted(img, color):
    arr = np.asarray(img, dtype=F32)
    arr[..., :3] *= np.array(color, F32) / 255.0
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")


def _font(size, bold=True):
    for p in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
    ):
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def checker(w, h, a=(236, 228, 214), b=(222, 212, 196), cell=12):
    img = Image.new("RGBA", (w, h), a + (255,))
    d = ImageDraw.Draw(img)
    for y in range(0, h, cell):
        for x in range(0, w, cell):
            if (x // cell + y // cell) % 2:
                d.rectangle([x, y, x + cell - 1, y + cell - 1], fill=b + (255,))
    return img


def render_sheet(path):
    names = sorted(TEXTURES)
    groups = ["panels", "buttons", "tabs", "cards", "tags", "ribbon", "bars", "misc", "patterns", "icons", "emblems"]
    pad = 18
    width = 1800
    font = _font(13, False)
    hfont = _font(22)
    rows = []  # (group, [(name, img)])
    for g in groups:
        items = [(n, TEXTURES[n]["img"]) for n in names if TEXTURES[n]["group"] == g]
        if items:
            rows.append((g, items))
    # layout pass
    placements = []
    y = 70
    for g, items in rows:
        placements.append(("h", g, 20, y))
        y += 34
        x = 20
        rowh = 0
        for n, img in items:
            w, h = img.size
            if g == "icons" or g == "emblems":
                w, h = 128, 128
            elif w > 512:
                w, h = 512, int(h * 512 / w)
            if x + w > width - 20:
                x = 20
                y += rowh + 26
                rowh = 0
            placements.append(("i", n, x, y, w, h))
            x += w + pad
            rowh = max(rowh, h)
        y += rowh + 40
    # 9-slice demos
    demo_y = y
    y += 330
    sheet = checker(width, y)
    d = ImageDraw.Draw(sheet)
    d.text((20, 18), "Trunkfall UI textures: scripts/make-ui-textures.py (checker = transparent)", font=hfont, fill=(60, 36, 18))
    for p in placements:
        if p[0] == "h":
            d.text((p[2], p[3]), p[1].upper(), font=hfont, fill=(110, 70, 40))
        else:
            _, n, x, yy, w, h = p
            img = TEXTURES[n]["img"]
            if img.size != (w, h):
                img = img.resize((w, h), Image.LANCZOS)
            sheet.alpha_composite(img, (x, yy))
            d.text((x, yy + h + 4), n, font=font, fill=(70, 46, 26))
    # demos: stretched panels, buttons with text, bar, ribbon
    d.text((20, demo_y), "9-SLICE DEMOS (rendered at the in-game slice scale)", font=hfont, fill=(110, 70, 40))
    yy = demo_y + 40
    pn, off = nine_slice(TEXTURES["ui_panel"]["img"], TEXTURES["ui_panel"]["slice"], 420, 240, 0.42)
    sheet.alpha_composite(pn, (20 - off[0], yy - off[1]))
    pn, off = nine_slice(TEXTURES["ui_panel_dark"]["img"], TEXTURES["ui_panel_dark"]["slice"], 300, 240, 0.42)
    sheet.alpha_composite(pn, (470 - off[0], yy - off[1]))
    bx = 800
    bfont = _font(20)
    for i, (v, label, col) in enumerate((("primary", "PLAY", (60, 36, 18)), ("secondary", "Details", (60, 36, 18)), ("danger", "Leave", (255, 255, 255)), ("robux", "R$ 99", (255, 255, 255)))):
        for j, st in enumerate(("", "_hover", "_pressed")):
            n = f"ui_btn_{v}{st}"
            b, off = nine_slice(TEXTURES[n]["img"], TEXTURES[n]["slice"], 150, 48, 0.42)
            px, py = bx + j * 170, yy + i * 62
            sheet.alpha_composite(b, (px - off[0], py - off[1]))
            draw_text_center(sheet, label, (px, py + (2 if st == "_pressed" else 0) - 3, px + 150, py + 48 - 6), bfont, col)
    tx = 1330
    for i, n in enumerate(("ui_tab_active", "ui_tab_inactive")):
        b, off = nine_slice(TEXTURES[n]["img"], TEXTURES[n]["slice"], 130, 40, 0.42)
        sheet.alpha_composite(b, (tx + i * 140 - off[0], yy - off[1]))
    for i, rar in enumerate(("common", "rare", "epic", "legendary")):
        base, off = nine_slice(tinted(TEXTURES["ui_card_base"]["img"], (255, 244, 214)), TEXTURES["ui_card_base"]["slice"], 100, 120, 0.4)
        px, py = tx + (i % 2) * 120 - 0, yy + 60 + (i // 2) * 0
        px = tx + i * 112
        py = yy + 60
        sheet.alpha_composite(base, (px - off[0], py - off[1]))
        fr, off = nine_slice(TEXTURES[f"ui_card_{rar}"]["img"], TEXTURES[f"ui_card_{rar}"]["slice"], 100, 120, 0.4)
        sheet.alpha_composite(fr, (px - off[0], py - off[1]))
    fr, off = nine_slice(TEXTURES["ui_bar_frame"]["img"], TEXTURES["ui_bar_frame"]["slice"], 300, 26, 0.45)
    sheet.alpha_composite(fr, (20 - off[0], yy + 270 - off[1]))
    fl, off = nine_slice(tinted(TEXTURES["ui_bar_fill"]["img"], (110, 210, 90)), TEXTURES["ui_bar_fill"]["slice"], 180, 26 - 7, 0.45)
    sheet.alpha_composite(fl, (24 - off[0], yy + 274 - off[1]))
    rb, off = nine_slice(TEXTURES["ui_ribbon"]["img"], TEXTURES["ui_ribbon"]["slice"], 300, 46, 0.45)
    sheet.alpha_composite(rb, (420 - off[0], yy + 262 - off[1]))
    draw_text_center(sheet, "TODAY'S PICKS", (420, yy + 262, 720, yy + 300), bfont, (255, 248, 230), stroke=(90, 30, 20))
    pt, off = nine_slice(TEXTURES["ui_price_tag"]["img"], TEXTURES["ui_price_tag"]["slice"], 120, 34, 0.45)
    sheet.alpha_composite(pt, (760 - off[0], yy + 268 - off[1]))
    draw_text_center(sheet, "1,200", (770, yy + 268, 880, yy + 302), _font(17), (60, 36, 18))
    sheet.convert("RGB").save(path)
    print("sheet ->", path)


def draw_text_center(img, text, box, font, color, stroke=None):
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = box
    bb = d.textbbox((0, 0), text, font=font, stroke_width=2 if stroke else 0)
    tw, th = bb[2] - bb[0], bb[3] - bb[1]
    x = x0 + (x1 - x0 - tw) / 2 - bb[0]
    y = y0 + (y1 - y0 - th) / 2 - bb[1]
    if stroke:
        d.text((x, y), text, font=font, fill=color, stroke_width=2, stroke_fill=stroke)
    else:
        d.text((x, y), text, font=font, fill=color)


def main(argv):
    build_all()
    write_outputs()
    if "--preview" in argv:
        i = argv.index("--preview")
        out = argv[i + 1] if i + 1 < len(argv) else "."
        os.makedirs(out, exist_ok=True)
        render_sheet(os.path.join(out, "sheet.png"))
        try:
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import importlib

            mock = importlib.import_module("ui_mock")
            mock.render(TEXTURES, out, nine_slice, tinted, _font, draw_text_center)
        except ModuleNotFoundError:
            pass


if __name__ == "__main__":
    main(sys.argv[1:])
