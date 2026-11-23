#!/usr/bin/env python3
"""Generates Trunkfall's animated icon atlases (menus and shop items).

    python3 scripts/make-icons.py               # writes assets/icons/icon_atlas_*.png,
                                                # src/client/UI/IconAtlas.luau and the
                                                # icon_* entries of assets/models/manifest.json
    python3 scripts/make-icons.py --preview DIR # also writes DIR/icons_sheet.png (not shipped)

Original art, drawn procedurally (no copied art, no fonts in the shipped
icons). Reuses the canvas / mask / filter toolkit and a few of the ui_ icon
drawings from scripts/make-ui-textures.py, in the clean ui2_ look: a crisp ink
outline, a soft drop shadow, two-tone gradient fills, one thin rim light and a
small specular, lit from the top-left.

Animation: every icon has FRAMES sprite frames side by side in its atlas row
(CELL x CELL px each). Frame 0 is the static look (Effects "off" shows only
that). The client (UI/AnimatedIcon) steps frames with ImageRectOffset and adds
idle motion in code. Anim kinds:
    shine    a light band sweeps across the icon (frames 1-3), then holds frame 0
    twinkle  sparkles grow and fade around the icon (loops)
    pulse    a soft coloured halo breathes behind the icon (loops)
    spin     the drawing itself turns (cogs; loops)
    wave     the drawing animates in steps (speaker waves, rings, flames; loops)
Each atlas is ATLAS x ATLAS (1024) with 2 icons per row and 8 rows; the last
slot of every atlas holds the shared soft "glow" sprite (hover glow).
"""

import importlib.util
import json
import math
import os
import sys

try:
    import numpy as np
    from PIL import Image, ImageFilter
except ImportError:  # pragma: no cover
    sys.exit("make-icons.py needs Pillow and numpy: pip install pillow numpy")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location("uitex", os.path.join(ROOT, "scripts", "make-ui-textures.py"))
U = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(U)

OUT_DIR = os.path.join(ROOT, "assets", "icons")
ATLAS_LUAU = os.path.join(ROOT, "src", "client", "UI", "IconAtlas.luau")
MANIFEST = U.MANIFEST

CELL = 128
FRAMES = 4
ATLAS = 1024
PER_ROW = ATLAS // (CELL * FRAMES)  # icons per row (2)
ROWS = ATLAS // CELL  # 8
SLOTS = PER_ROW * ROWS - 1  # the last slot holds the glow sprite

Canvas = U.Canvas
m_rrect, m_ellipse, m_poly, m_line, m_arc, m_rot_rect = U.m_rrect, U.m_ellipse, U.m_poly, U.m_line, U.m_arc, U.m_rot_rect
union, sub, inter, dilate, erode, blur, shift, roundify = U.union, U.sub, U.inter, U.dilate, U.erode, U.blur, U.shift, U.roundify
vgrad, radial, glow, drop_shadow, emboss, inner_shadow = U.vgrad, U.radial, U.glow, U.drop_shadow, U.emboss, U.inner_shadow
star_mask, sparkle = U.star_mask, U.sparkle
lighten, darken = U.lighten, U.darken
F32 = U.F32
WHITE = U.WHITE
INK = U.U2_INK
PINK = U.PINK

# two-tone fills (top, bottom)
GOLD = ((255, 232, 130), (226, 146, 18))
RED = ((255, 130, 112), (196, 46, 40))
GREEN = ((150, 236, 120), (40, 150, 70))
BLUE = ((136, 206, 255), (40, 112, 214))
PURPLE = ((214, 170, 255), (124, 70, 206))
STEEL = ((240, 244, 250), (140, 150, 168))
WOOD = ((222, 164, 104), (140, 88, 44))
ORANGE = ((255, 200, 110), (226, 108, 20))
TEAL = ((130, 240, 222), (20, 150, 150))
CREAM = ((255, 251, 238), (226, 206, 168))
MAGENTA = ((255, 150, 230), (200, 40, 170))
GREY = ((222, 228, 236), (128, 138, 152))
DARK = ((110, 96, 130), (52, 40, 70))


# ---------------------------------------------------------------- style helpers


def ol(c, mask, width=4.5, shadow=True):
    """ui2 outline: a soft drop shadow, then the ink outline under the shape."""
    o = dilate(mask, width)
    if shadow:
        drop_shadow(c, o, 0, 3.5, 3.2, 0.3, (40, 24, 12))
    c.paint(INK, o)


def body(c, mask, cols, y0=None, y1=None, rim=True, bevel=2.2):
    """Two-tone gradient fill + one thin top rim light + a soft lower shade."""
    ys = np.where(mask > 0.5)[0]
    if y0 is None:
        y0 = (ys.min() / U.SS) if len(ys) else 0
        y1 = (ys.max() / U.SS) if len(ys) else c.h
    top, bot = cols
    c.paint(vgrad(c, [(0, lighten(top, 0.1)), (0.55, top), (1, bot)], y0, y1), mask)
    if bevel:
        emboss(c, mask, bevel, 0.35, 0.22)
    if rim:
        r = sub(mask, shift(mask, 0, 2.6)) * (c.Y < (y0 + y1) / 2)
        c.tint(WHITE, r, 0.6)


def spec(c, x, y, rx, ry, op=0.75):
    c.paint(WHITE, m_ellipse(c, x, y, rx, ry), op)


def lines(c, mask, pts_list, width, color=INK, op=0.8):
    for pts in pts_list:
        c.paint(color, inter(m_line(c, pts, width), mask), op)


def ring(c, cx, cy, r, w):
    return sub(m_ellipse(c, cx, cy, r + w / 2), m_ellipse(c, cx, cy, r - w / 2))


def poly_star(cx, cy, ro, ri, n=5, rot=-90):
    pts = []
    for i in range(n * 2):
        a = math.radians(rot + i * 180 / n)
        r = ro if i % 2 == 0 else ri
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def rotp(pts, cx, cy, deg):
    a = math.radians(deg)
    ca, sa = math.cos(a), math.sin(a)
    return [(cx + (x - cx) * ca - (y - cy) * sa, cy + (x - cx) * sa + (y - cy) * ca) for x, y in pts]


def mini_badge(c, kind, color=GREEN, cx=100, cy=100, r=17):
    """Small corner badge: 'plus', 'cross', 'up', 'two' (x2), 'star', 'check'."""
    disc = m_ellipse(c, cx, cy, r)
    ol(c, disc, 3.2, shadow=False)
    body(c, disc, color)
    if kind == "plus":
        g = union(m_rrect(c, cx - 3.5, cy - 10, cx + 3.5, cy + 10, 2), m_rrect(c, cx - 10, cy - 3.5, cx + 10, cy + 3.5, 2))
    elif kind == "cross":
        g = union(m_rot_rect(c, cx, cy, 6.5, 22, 45, 0), m_rot_rect(c, cx, cy, 6.5, 22, -45, 0))
    elif kind == "up":
        g = union(m_poly(c, [(cx, cy - 11), (cx + 10, cy), (cx - 10, cy)]), m_rrect(c, cx - 3.5, cy - 2, cx + 3.5, cy + 10, 1.5))
    elif kind == "two":
        # "x2" as two stacked chevrons (no font): reads as "double"
        g = union(
            m_line(c, [(cx - 8, cy - 1), (cx, cy - 8), (cx + 8, cy - 1)], 4.2),
            m_line(c, [(cx - 8, cy + 7), (cx, cy), (cx + 8, cy + 7)], 4.2),
        )
    elif kind == "star":
        g = m_poly(c, poly_star(cx, cy + 1, 11, 4.8))
    else:  # check
        g = m_line(c, [(cx - 8, cy), (cx - 2, cy + 6), (cx + 9, cy - 6)], 4.5)
    c.paint(WHITE, g)


# ---------------------------------------------------------------- glyphs
# Each glyph(c, t) draws on a 128 x 128 canvas; t in [0, 1) is the animation
# phase (only "spin" / "wave" glyphs use it).


def wrap(fn):
    """Adapts a ui_ icon function (returns its own canvas) to a glyph."""

    def g(c, t):
        src = fn()
        c.rgb, c.a = src.rgb, src.a

    return g


def g_robot(c, t):
    head = m_rrect(c, 22, 38, 106, 108, 22)
    ant = m_rrect(c, 61, 14, 67, 40, 3)
    ball = m_ellipse(c, 64, 14, 9)
    ears = union(m_rrect(c, 12, 60, 24, 88, 5), m_rrect(c, 104, 60, 116, 88, 5))
    ol(c, union(head, ant, ball, ears))
    body(c, ears, GREY)
    body(c, ant, GREY)
    body(c, ball, RED)
    body(c, head, STEEL)
    visor = m_rrect(c, 32, 56, 96, 88, 14)
    c.paint((44, 52, 72), visor)
    blink = 1.0 if t < 0.75 else 0.25  # blinks once per loop
    for ex in (50, 78):
        e = m_ellipse(c, ex, 72, 8, 8 * blink)
        glow(c, e, 3, (120, 220, 255), 0.6)
        c.paint((150, 236, 255), e)
    c.paint(WHITE, m_ellipse(c, 47, 69, 2.5, 2.5 * blink), 0.9)
    c.paint(INK, m_rrect(c, 50, 96, 78, 99, 1.5), 0.6)
    spec(c, 40, 46, 10, 4, 0.5)


def g_cart(c, t):
    basket = m_poly(c, [(26, 40), (112, 40), (100, 84), (38, 84)])
    handle = m_line(c, [(8, 26), (22, 26), (40, 92), (100, 92)], 7, caps=True)
    wheels = union(m_ellipse(c, 48, 106, 10), m_ellipse(c, 94, 106, 10))
    wedge = m_poly(c, [(44, 40), (84, 20), (98, 40)])
    ol(c, union(basket, handle, wheels, wedge))
    body(c, wedge, GOLD)
    body(c, basket, RED)
    for x in (48, 64, 80, 96):
        c.tint(darken(RED[1], 0.3), inter(m_rrect(c, x - 1.5, 44, x + 1.5, 80, 1), basket), 0.55)
    c.tint(darken(RED[1], 0.3), inter(m_rrect(c, 30, 60, 110, 63, 1), basket), 0.55)
    body(c, handle, STEEL, rim=False)
    for wx in (48, 94):
        body(c, m_ellipse(c, wx, 106, 10), GREY)
        c.paint(INK, m_ellipse(c, wx, 106, 3.5), 0.8)


def speaker(c):
    box = m_rrect(c, 14, 46, 40, 82, 5)
    cone = m_poly(c, [(36, 48), (66, 22), (66, 106), (36, 80)])
    m = roundify(union(box, cone), 1.5)
    return m


def g_sound_on(c, t):
    m = speaker(c)
    k = int(t * 4) % 4  # 0..3 waves
    waves = []
    for i in range(min(3, k + 1) if k > 0 else 1):
        r = 22 + i * 16
        waves.append(m_arc(c, 66, 64, r, -48, 48, 7))
    w = union(*waves)
    ol(c, union(m, w))
    body(c, m, ORANGE)
    body(c, w, CREAM, rim=False, bevel=0)


def g_sound_off(c, t):
    m = speaker(c)
    x = union(m_rot_rect(c, 96, 64, 10, 42, 45, 3), m_rot_rect(c, 96, 64, 10, 42, -45, 3))
    ol(c, union(m, x))
    body(c, m, GREY)
    body(c, x, RED, bevel=0)


def g_cog(c, t, cols=STEEL, cx=64, cy=64, R=46, teeth=8):
    rot = t * (360 / teeth)
    pts = []
    for i in range(teeth * 4):
        a = math.radians(rot + i * 360 / (teeth * 4))
        r = R if (i % 4) in (1, 2) else R - 13
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    gear = sub(roundify(m_poly(c, pts), 1.8), m_ellipse(c, cx, cy, R * 0.3))
    ol(c, gear)
    body(c, gear, cols)
    hub = ring(c, cx, cy, R * 0.47, 5)
    c.tint(darken(cols[1], 0.25), hub * gear, 0.5)


def g_smile(c, t):
    face = m_ellipse(c, 64, 64, 50)
    ol(c, face)
    body(c, face, ((255, 236, 120), (240, 168, 30)))
    for ex in (46, 82):
        c.paint(INK, m_ellipse(c, ex, 54, 6, 9))
        c.paint(WHITE, m_ellipse(c, ex - 2, 50, 2, 2.5))
    c.paint(INK, m_arc(c, 64, 64, 28, 25, 155, 6))
    for cx in (32, 96):
        c.paint(PINK, m_ellipse(c, cx, 74, 8, 5), 0.65)
    spec(c, 44, 28, 12, 6, 0.5)


def diamond(c, cx, cy, s, cols):
    top = [(cx - 40 * s, cy - 12 * s), (cx - 22 * s, cy - 34 * s), (cx + 22 * s, cy - 34 * s), (cx + 40 * s, cy - 12 * s)]
    pts = top + [(cx, cy + 40 * s)]
    m = m_poly(c, pts)
    return m, top


def g_gem(c, t, cols=BLUE):
    m, top = diamond(c, 64, 66, 1.25, cols)
    ol(c, m)
    body(c, m, cols, bevel=0)
    cx, cy, s = 64, 66, 1.25
    crown = m_poly(c, top)
    c.tint(WHITE, inter(crown, m), 0.25)
    # facets
    for pts, col, op in (
        ([(cx - 22 * s, cy - 34 * s), (cx, cy - 12 * s), (cx - 40 * s, cy - 12 * s)], WHITE, 0.35),
        ([(cx + 22 * s, cy - 34 * s), (cx + 40 * s, cy - 12 * s), (cx, cy - 12 * s)], U.SHADOW, 0.15),
        ([(cx - 40 * s, cy - 12 * s), (cx, cy - 12 * s), (cx, cy + 40 * s)], WHITE, 0.15),
        ([(cx + 40 * s, cy - 12 * s), (cx, cy + 40 * s), (cx, cy - 12 * s)], U.SHADOW, 0.25),
    ):
        c.tint(col, inter(m_poly(c, pts), m), op)
    c.paint(INK, inter(m_rrect(c, 0, cy - 12 * s - 1, 128, cy - 12 * s + 1, 0), m), 0.35)
    spec(c, 46, 34, 7, 4, 0.8)


def g_ladder(c, t):
    rails = union(m_rot_rect(c, 44, 64, 10, 116, 12, 3), m_rot_rect(c, 84, 64, 10, 116, 12, 3))
    rungs = []
    for i in range(5):
        y = 22 + i * 21
        x = 64 + (64 - y) * math.tan(math.radians(12)) * -1
        rungs.append(m_rot_rect(c, x + 0, y, 44, 8, 12, 2))
    r = union(*rungs)
    ol(c, union(rails, r))
    body(c, r, WOOD)
    body(c, rails, ((236, 184, 120), (150, 96, 48)))


def g_horn(c, t):
    tube = m_line(c, [(18, 92), (40, 84), (66, 70), (88, 54)], 12)
    bell = m_poly(c, [(80, 58), (112, 18), (122, 66), (92, 66)])
    bell = roundify(union(bell, m_ellipse(c, 112, 42, 13, 26)), 2)
    mouth = m_ellipse(c, 14, 94, 8)
    cord = m_arc(c, 54, 92, 22, 20, 160, 4)
    ol(c, union(tube, bell, mouth, cord))
    body(c, cord, RED, rim=False, bevel=0)
    body(c, tube, GOLD)
    body(c, bell, GOLD)
    c.tint(darken(GOLD[1], 0.35), inter(m_ellipse(c, 112, 42, 7, 18), bell), 0.7)
    body(c, mouth, STEEL)
    k = int(t * 4)
    for i in range(k):
        nx, ny = 34 + i * 14, 34 - i * 8
        n = union(m_ellipse(c, nx, ny + 10, 6, 5), m_rrect(c, nx + 3, ny - 8, nx + 6.5, ny + 10, 1.5))
        ol(c, n, 2.5, shadow=False)
        c.paint(CREAM[0], n)


def g_tophat(c, t, cols=DARK, band=RED):
    crown = m_rrect(c, 34, 16, 94, 86, 8)
    brim = m_ellipse(c, 64, 92, 54, 14)
    ol(c, union(crown, brim))
    body(c, brim, cols)
    body(c, crown, cols)
    b = inter(m_rrect(c, 34, 64, 94, 80, 0), crown)
    body(c, b, band, rim=False)
    spec(c, 46, 30, 5, 12, 0.35)


def g_stall(c, t):
    counter = m_rrect(c, 18, 74, 110, 112, 6)
    posts = union(m_rrect(c, 22, 40, 30, 80, 2), m_rrect(c, 98, 40, 106, 80, 2))
    awning = m_poly(c, [(10, 46), (24, 14), (104, 14), (118, 46)])
    scallop = union(*[m_ellipse(c, 18 + i * 18.4, 46, 9.2, 8) for i in range(6)])
    aw = union(awning, scallop)
    ol(c, union(counter, posts, aw))
    body(c, posts, WOOD)
    body(c, counter, WOOD)
    c.tint(darken(WOOD[1], 0.2), inter(m_rrect(c, 18, 90, 110, 93, 1), counter), 0.6)
    body(c, aw, RED)
    for i in range(6):
        if i % 2 == 0:
            stripe = m_poly(c, [(10 + i * 18, 46), (24 + i * 13.3, 14), (24 + (i + 1) * 13.3, 14), (10 + (i + 1) * 18, 46)])
            c.tint(CREAM[0], inter(union(stripe, m_ellipse(c, 18 + i * 18.4, 46, 9.2, 8)), aw), 0.9)
    w = m_poly(c, [(40, 74), (60, 60), (70, 74)])
    ol(c, w, 2.5, shadow=False)
    body(c, w, GOLD, bevel=0)
    coin = m_ellipse(c, 88, 68, 9)
    ol(c, coin, 2.5, shadow=False)
    body(c, coin, GOLD, bevel=0)


def g_medal(c, t, cols=GOLD, ribbon=(BLUE, RED)):
    r1 = m_poly(c, [(36, 8), (58, 8), (74, 60), (54, 64)])
    r2 = m_poly(c, [(70, 8), (92, 8), (74, 64), (54, 60)])
    disc = m_ellipse(c, 64, 82, 34)
    ol(c, union(r1, r2, disc))
    body(c, r1, ribbon[0])
    body(c, r2, ribbon[1])
    body(c, disc, cols)
    c.tint(darken(cols[1], 0.3), ring(c, 64, 82, 24, 3) * disc, 0.6)
    st = m_poly(c, poly_star(64, 84, 16, 7))
    c.paint(lighten(cols[0], 0.5), st)
    spec(c, 50, 64, 7, 4, 0.7)


def g_levelup(c, t):
    disc = m_ellipse(c, 64, 64, 50)
    ol(c, disc)
    body(c, disc, GREEN)
    a = union(m_poly(c, [(64, 22), (96, 58), (76, 58), (76, 98), (52, 98), (52, 58), (32, 58)]))
    a = roundify(a, 1.5)
    c.paint(INK, dilate(a, 2.5), 0.8)
    body(c, a, ((255, 255, 236), (220, 236, 200)), bevel=1.2)


def g_tree(c, t):
    trunk = m_poly(c, [(54, 120), (58, 72), (70, 72), (74, 120)])
    blobs = union(m_ellipse(c, 64, 42, 32), m_ellipse(c, 36, 64, 24), m_ellipse(c, 92, 64, 24), m_ellipse(c, 64, 70, 26))
    ol(c, union(trunk, blobs))
    body(c, trunk, WOOD)
    body(c, blobs, GREEN)
    for (x, y) in ((50, 40), (82, 58), (40, 70), (70, 76)):
        f = m_ellipse(c, x, y, 5)
        c.paint(GOLD[0], f)
        c.paint(INK, sub(dilate(f, 1.2), f), 0.5)


def g_crown(c, t, cols=GOLD):
    pts = [(14, 96), (14, 40), (40, 66), (64, 22), (88, 66), (114, 40), (114, 96)]
    m = roundify(m_poly(c, pts), 2.5)
    band = m_rrect(c, 12, 88, 116, 110, 6)
    tips = union(m_ellipse(c, 14, 36, 8), m_ellipse(c, 64, 18, 9), m_ellipse(c, 114, 36, 8))
    ol(c, union(m, band, tips))
    body(c, m, cols)
    body(c, tips, cols)
    body(c, band, (lighten(cols[0], 0.1), darken(cols[1], 0.1)))
    for x, col in ((40, (60, 200, 110)), (64, (230, 70, 60)), (88, (70, 150, 240))):
        g = m_ellipse(c, x, 99, 6.5)
        c.paint(INK, dilate(g, 1.5), 0.8)
        c.paint(col, g)
        c.paint(WHITE, m_ellipse(c, x - 2, 97, 2, 1.5), 0.9)


def g_burst(c, t, cols=ORANGE, inner=BLUE):
    pts = poly_star(64, 64, 58, 32, 8, -90 + t * 22.5)
    m = roundify(m_poly(c, pts), 2)
    ol(c, m)
    body(c, m, cols)
    orb = m_ellipse(c, 64, 64, 24)
    glow(c, orb, 4, lighten(inner[0], 0.3), 0.6)
    body(c, orb, inner)
    bolt = m_poly(c, [(68, 46), (54, 68), (64, 68), (58, 84), (74, 60), (64, 60), (70, 46)])
    c.paint(WHITE, bolt)


def g_palette(c, t):
    p = sub(roundify(union(m_ellipse(c, 62, 66, 54, 46)), 2), m_ellipse(c, 88, 90, 10))
    ol(c, p)
    body(c, p, WOOD)
    for x, y, col in ((36, 52, RED), (60, 36, GOLD), (86, 44, BLUE), (34, 80, GREEN), (58, 92, PURPLE)):
        b = m_ellipse(c, x, y, 10)
        c.paint(INK, dilate(b, 1.8), 0.85)
        body(c, b, col, bevel=1)


def g_chevrons(c, t):
    ms = []
    for i in range(3):
        y = 92 - i * 30
        ms.append(m_line(c, [(24, y + 14), (64, y - 16), (104, y + 14)], 16))
    m = union(*ms)
    ol(c, m)
    for i, mm in enumerate(ms):
        body(c, mm, GOLD if i == 2 else ORANGE)


def g_clipboard(c, t):
    board = m_rrect(c, 20, 18, 108, 120, 10)
    clip = m_rrect(c, 42, 8, 86, 30, 6)
    ol(c, union(board, clip))
    body(c, board, WOOD)
    paper = m_rrect(c, 30, 28, 98, 112, 4)
    c.paint(CREAM[0], paper)
    body(c, clip, STEEL)
    for i in range(4):
        y = 46 + i * 18
        box = m_rrect(c, 38, y - 6, 50, y + 6, 2)
        c.paint(INK, sub(dilate(box, 1.5), box), 0.8)
        c.paint((150, 110, 70), m_rrect(c, 56, y - 2, 90 - (i % 2) * 12, y + 2, 2), 0.7)
        if i < 2:
            c.paint(GREEN[1], m_line(c, [(39, y), (43, y + 4), (50, y - 6)], 3))


def g_tools(c, t):
    wrench = m_rot_rect(c, 64, 64, 14, 96, 45, 4)
    head_w = sub(m_ellipse(c, 30, 30, 20), m_rot_rect(c, 24, 24, 12, 28, 45, 0))
    hammer_h = m_rot_rect(c, 64, 64, 12, 96, -45, 3)
    hammer = m_rot_rect(c, 94, 34, 22, 46, -45, 3)
    ol(c, union(wrench, head_w, hammer_h, hammer))
    body(c, hammer_h, WOOD)
    body(c, union(wrench, head_w), STEEL)
    body(c, hammer, GREY)


def g_sparkles(c, t):
    for (x, y, r) in ((54, 62, 40), (98, 30, 20), (96, 96, 16)):
        m = m_poly(c, poly_star(x, y, r, r * 0.28, 4, -90))
        ol(c, m, 3.5)
        body(c, m, GOLD, bevel=1)


def g_flower(c, t, petal=PINK):
    stem = m_line(c, [(64, 120), (62, 80)], 8)
    leaf = m_rot_rect(c, 80, 96, 26, 12, -30, 5)
    petals = union(*[m_ellipse(c, 64 + 22 * math.cos(math.radians(a)), 50 + 22 * math.sin(math.radians(a)), 16) for a in range(-90, 270, 72)])
    core = m_ellipse(c, 64, 50, 13)
    ol(c, union(stem, leaf, petals, core))
    body(c, union(stem, leaf), GREEN)
    body(c, petals, (lighten(petal, 0.4), petal))
    body(c, core, GOLD)


def g_grid(c, t):
    ms = [m_rrect(c, x, y, x + 46, y + 46, 10) for x in (14, 68) for y in (14, 68)]
    ol(c, union(*ms))
    for m, col in zip(ms, (GOLD, BLUE, GREEN, RED)):
        body(c, m, col)


def g_trail(c, t):
    tail = m_poly(c, [(12, 112), (66, 52), (82, 70)])
    tail2 = m_poly(c, [(20, 80), (62, 50), (66, 60)])
    tail3 = m_poly(c, [(46, 118), (72, 66), (80, 74)])
    head = m_poly(c, poly_star(86, 44, 34, 15, 5, -100))
    head = roundify(head, 2)
    ol(c, union(tail, tail2, tail3, head))
    c.paint(vgrad(c, [(0, (180, 220, 255)), (1, (120, 90, 230))]), union(tail, tail2, tail3))
    body(c, head, GOLD)


def g_drop(c, t, cols=BLUE):
    m = roundify(union(m_ellipse(c, 64, 78, 36), m_poly(c, [(64, 8), (96, 64), (32, 64)])), 2)
    ol(c, m)
    body(c, m, cols)
    spec(c, 50, 72, 7, 12, 0.6)


def g_check(c, t):
    disc = m_ellipse(c, 64, 64, 50)
    ol(c, disc)
    body(c, disc, GREEN)
    ck = m_line(c, [(38, 66), (56, 84), (92, 44)], 15)
    c.paint(INK, dilate(ck, 2), 0.6)
    body(c, ck, ((255, 255, 240), (220, 240, 210)), bevel=1)


def g_rind(c, t):
    m = roundify(m_poly(c, [(64, 10), (112, 64), (64, 118), (16, 64)]), 3)
    ol(c, m)
    body(c, m, ORANGE, bevel=0)
    c.tint(WHITE, inter(m_poly(c, [(64, 10), (16, 64), (64, 64)]), m), 0.3)
    c.tint(U.SHADOW, inter(m_poly(c, [(64, 118), (112, 64), (64, 64)]), m), 0.2)
    inner = roundify(m_poly(c, [(64, 34), (88, 64), (64, 94), (40, 64)]), 2)
    c.tint(lighten(ORANGE[0], 0.5), inner, 0.45)


def g_milk(c, t):
    bottle = roundify(union(m_rrect(c, 32, 50, 96, 120, 14), m_poly(c, [(32, 56), (48, 30), (80, 30), (96, 56)])), 2)
    cap = m_rrect(c, 44, 12, 84, 32, 5)
    ol(c, union(bottle, cap))
    body(c, bottle, ((255, 255, 255), (206, 220, 236)))
    body(c, cap, BLUE)
    label = m_rrect(c, 40, 70, 88, 100, 6)
    c.paint(BLUE[0], inter(label, bottle), 0.9)
    d = m_poly(c, poly_star(64, 85, 10, 4.5, 5))
    c.paint(WHITE, d)
    spec(c, 44, 66, 4, 14, 0.6)


def g_flag(c, t, cols=RED):
    pole = m_rrect(c, 22, 10, 31, 122, 3)
    knob = m_ellipse(c, 26, 10, 8)
    wave = 6 * math.sin(t * 2 * math.pi)
    flag = roundify(m_poly(c, [(30, 18), (70, 14 + wave), (112, 20), (98, 46), (112, 72), (70, 66 - wave), (30, 72)]), 2)
    ol(c, union(pole, knob, flag))
    body(c, pole, WOOD)
    body(c, knob, GOLD)
    body(c, flag, cols)
    st = m_poly(c, poly_star(62, 43, 13, 5.5))
    c.paint(lighten(cols[0], 0.6), st)


def g_shield(c, t, cols=BLUE, star=True):
    sh = U.shield_mask(c)
    ol(c, sh)
    body(c, sh, GOLD)
    inner = erode(sh, 9)
    c.paint(INK, sub(dilate(inner, 1.4), inner) * sh, 0.8)
    body(c, inner, cols)
    if star:
        st = m_poly(c, poly_star(64, 62, 26, 11))
        c.paint(INK, dilate(st, 2.4), 0.8)
        body(c, st, ((255, 255, 236), (240, 210, 140)), bevel=1)


def g_wardrobe(c, t, plus=False):
    box = m_rrect(c, 22, 10, 106, 116, 8)
    feet = union(m_rrect(c, 28, 112, 40, 122, 2), m_rrect(c, 88, 112, 100, 122, 2))
    ol(c, union(box, feet))
    body(c, feet, WOOD)
    body(c, box, ((210, 150, 230), (120, 70, 160)))
    c.paint(INK, m_rrect(c, 62.5, 16, 65.5, 110, 1), 0.85)
    for x in (54, 74):
        k = m_ellipse(c, x, 62, 4.5)
        c.paint(INK, dilate(k, 1.2))
        c.paint(GOLD[0], k)
    for x0 in (30, 70):
        c.tint(WHITE, m_rrect(c, x0, 20, x0 + 28, 50, 5), 0.18)
    if plus:
        mini_badge(c, "plus", GREEN, 100, 98, 19)


def g_brush(c, t, tip=GOLD, neon=False):
    handle = m_rot_rect(c, 52, 76, 14, 80, 40, 6)
    ferrule = m_rot_rect(c, 82, 42, 20, 20, 40, 2)
    bristle = roundify(m_poly(c, rotp([(80, 22), (100, 22), (98, 2), (90, -8), (82, 2)], 90, 32, 40)), 2)
    blob = m_ellipse(c, 30, 104, 22, 12)
    if neon:
        glow(c, union(bristle, blob), 7, tip[0], 0.75)
    ol(c, union(handle, ferrule, bristle, blob))
    body(c, blob, tip)
    body(c, handle, WOOD)
    body(c, ferrule, STEEL)
    body(c, bristle, tip)


def heart_mask(c, cx, cy, s):
    m = union(m_ellipse(c, cx - 18 * s, cy - 8 * s, 21 * s), m_ellipse(c, cx + 18 * s, cy - 8 * s, 21 * s), m_poly(c, [(cx - 37 * s, cy - 2 * s), (cx + 37 * s, cy - 2 * s), (cx, cy + 40 * s)]))
    return roundify(m, 2)


def g_heart_wings(c, t):
    flap = 6 * math.sin(t * 2 * math.pi)
    wl = roundify(m_poly(c, [(40, 58), (6, 34 - flap), (12, 56 - flap), (2, 64 - flap), (16, 76), (8, 84), (36, 84)]), 2)
    wr = roundify(m_poly(c, [(88, 58), (122, 34 - flap), (116, 56 - flap), (126, 64 - flap), (112, 76), (120, 84), (92, 84)]), 2)
    h = heart_mask(c, 64, 64, 1.0)
    ol(c, union(wl, wr, h))
    body(c, union(wl, wr), ((255, 255, 255), (196, 214, 236)))
    body(c, h, RED)
    spec(c, 50, 50, 7, 4.5, 0.75)


def g_heart_plus(c, t):
    h = heart_mask(c, 64, 64, 1.25)
    ol(c, h)
    body(c, h, RED)
    p = union(m_rrect(c, 56, 40, 72, 84, 3), m_rrect(c, 42, 54, 86, 70, 3))
    c.paint(INK, dilate(p, 2), 0.5)
    c.paint(WHITE, p)


def g_clock(c, t, cols=GREEN):
    body_m = m_ellipse(c, 64, 70, 48)
    btn = m_rrect(c, 54, 8, 74, 22, 3)
    stem = m_rrect(c, 59, 18, 69, 26, 1)
    ol(c, union(body_m, btn, stem))
    body(c, union(btn, stem), STEEL)
    body(c, body_m, cols)
    face = m_ellipse(c, 64, 70, 38)
    c.paint(CREAM[0], face)
    for i in range(12):
        a = math.radians(i * 30)
        c.paint(INK, m_line(c, [(64 + 32 * math.cos(a), 70 + 32 * math.sin(a)), (64 + 35 * math.cos(a), 70 + 35 * math.sin(a))], 2.5), 0.7)
    a = math.radians(-90 + t * 360)
    c.paint(RED[1], m_line(c, [(64, 70), (64 + 28 * math.cos(a), 70 + 28 * math.sin(a))], 4.5))
    c.paint(INK, m_ellipse(c, 64, 70, 5))


def g_cheese_rush(c, t):
    for i, y in enumerate((44, 64, 84)):
        sl = m_rrect(c, 6 + i * 4 - (t * 10 % 10), y - 3, 40 + i * 4, y + 3, 3)
        c.paint(CREAM[0], sl, 0.9)
        c.paint(INK, sub(dilate(sl, 2), sl), 0.6)
    w = roundify(m_poly(c, [(44, 92), (96, 30), (122, 58), (122, 98), (44, 108)]), 2)
    ol(c, w)
    body(c, w, GOLD)
    for (x, y, r) in ((80, 80, 7), (102, 70, 5), (98, 92, 5)):
        c.tint(darken(GOLD[1], 0.15), m_ellipse(c, x, y, r), 0.85)


def g_plate(c, t):
    plate = m_ellipse(c, 64, 92, 58, 22)
    ol(c, plate)
    body(c, plate, ((255, 255, 255), (200, 210, 224)))
    c.tint(darken((200, 210, 224), 0.1), m_ellipse(c, 64, 90, 40, 12), 0.5)
    w1 = roundify(m_poly(c, [(22, 84), (60, 40), (78, 58), (78, 92), (22, 96)]), 2)
    w2 = roundify(m_poly(c, [(58, 90), (92, 34), (110, 54), (110, 92), (58, 98)]), 2)
    ol(c, union(w1, w2), 3.5, shadow=False)
    body(c, w1, GOLD)
    c.paint(INK, sub(dilate(w2, 2.5), w2), 0.9)
    body(c, w2, GOLD)
    for (x, y) in ((52, 80), (92, 74), (84, 88)):
        c.tint(darken(GOLD[1], 0.15), m_ellipse(c, x, y, 5), 0.85)


def g_cycle(c, t, cols=PURPLE, coin=True):
    rot = t * 90
    if coin:
        disc = m_ellipse(c, 64, 64, 54)
        ol(c, disc)
        body(c, disc, GOLD)
        c.tint(darken(GOLD[1], 0.3), ring(c, 64, 64, 44, 3) * disc, 0.6)
    a1 = m_arc(c, 64, 64, 30, 200 + rot, 340 + rot, 10)
    a2 = m_arc(c, 64, 64, 30, 20 + rot, 160 + rot, 10)
    heads = []
    for base in (340 + rot, 160 + rot):
        a = math.radians(base)
        x, y = 64 + 30 * math.cos(a), 64 + 30 * math.sin(a)
        tx, ty = -math.sin(a), math.cos(a)
        nx, ny = math.cos(a), math.sin(a)
        heads.append(m_poly(c, [(x + tx * 14, y + ty * 14), (x + nx * 12, y + ny * 12), (x - nx * 12, y - ny * 12)]))
    m = union(a1, a2, *heads)
    c.paint(INK, dilate(m, 2.5), 0.9)
    body(c, m, cols, bevel=1)


def g_box(c, t):
    front = m_poly(c, [(14, 50), (64, 70), (64, 122), (14, 100)])
    side = m_poly(c, [(64, 70), (114, 50), (114, 100), (64, 122)])
    top = m_poly(c, [(14, 50), (64, 30), (114, 50), (64, 70)])
    ol(c, union(front, side, top))
    body(c, front, WOOD)
    body(c, side, (darken(WOOD[0], 0.1), darken(WOOD[1], 0.2)))
    body(c, top, (lighten(WOOD[0], 0.2), WOOD[0]))
    band = union(m_poly(c, [(34, 42), (44, 38), (94, 58), (84, 62)]), m_poly(c, [(84, 62), (94, 58), (94, 108), (84, 113)]))
    c.paint(RED[1], inter(band, union(front, side, top)), 0.9)
    st = m_poly(c, poly_star(40, 84, 13, 5.5))
    c.paint(GOLD[0], st)


def g_bubble(c, t):
    b = roundify(union(m_ellipse(c, 64, 56, 54, 42), m_poly(c, [(36, 86), (26, 118), (64, 92)])), 2)
    ol(c, b)
    body(c, b, ((255, 255, 255), (206, 220, 236)))
    for ex in (48, 80):
        c.paint(INK, m_ellipse(c, ex, 46, 5, 7))
    c.paint(INK, m_arc(c, 64, 52, 20, 25, 155, 5))
    c.paint(PINK, m_ellipse(c, 36, 62, 6, 4), 0.6)
    c.paint(PINK, m_ellipse(c, 92, 62, 6, 4), 0.6)


def g_card(c, t):
    card = m_rot_rect(c, 64, 66, 108, 72, -10, 10)
    ol(c, card)
    body(c, card, TEAL)
    strip = inter(m_rot_rect(c, 64, 52, 130, 14, -10, 0), card)
    c.paint(darken(TEAL[1], 0.4), strip, 0.85)
    w = roundify(m_poly(c, rotp([(24, 90), (48, 66), (60, 90)], 64, 66, -10)), 1)
    c.paint(INK, dilate(w, 2), 0.8)
    body(c, w, GOLD, bevel=0)
    chip = m_rot_rect(c, 94, 82, 22, 16, -10, 3)
    body(c, chip, GOLD, bevel=0)


def g_magnet(c, t):
    arc = m_arc(c, 64, 60, 34, 180, 360, 24)
    legs = union(m_rrect(c, 18, 58, 42, 100, 2), m_rrect(c, 86, 58, 110, 100, 2))
    tips = union(m_rrect(c, 18, 96, 42, 116, 2), m_rrect(c, 86, 96, 110, 116, 2))
    ol(c, union(arc, legs, tips))
    body(c, union(arc, legs), RED)
    body(c, tips, STEEL)
    k = t * 4
    for (x, y) in ((54, 112), (74, 120)):
        cr = m_ellipse(c, x, y - (int(k) % 2) * 3, 5)
        c.paint(GOLD[1], cr)


def g_sniff(c, t):
    w = roundify(m_poly(c, [(16, 112), (70, 62), (98, 88), (98, 116), (16, 122)]), 2)
    ol(c, w)
    body(c, w, GOLD)
    for (x, y, r) in ((60, 102, 6), (82, 96, 5)):
        c.tint(darken(GOLD[1], 0.15), m_ellipse(c, x, y, r), 0.85)
    ph = t * 2 * math.pi
    for i in range(3):
        x0 = 50 + i * 20
        pts = [(x0 + 7 * math.sin(ph + k * 0.9 + i), 56 - k * 10) for k in range(5)]
        s = m_line(c, pts, 5)
        c.paint(INK, dilate(s, 2), 0.7)
        c.paint((200, 236, 160), s)


def g_tusk(c, t):
    tusk = roundify(m_poly(c, [(26, 112), (40, 108), (78, 76), (106, 30), (110, 14), (96, 26), (66, 62), (20, 96)]), 3)
    ol(c, tusk)
    body(c, tusk, ((255, 252, 238), (220, 200, 160)))
    band = inter(m_rot_rect(c, 36, 100, 30, 10, -40, 0), tusk)
    c.paint(GOLD[1], band, 0.9)
    clover = union(*[m_ellipse(c, 92 + 9 * math.cos(math.radians(a)), 92 + 9 * math.sin(math.radians(a)), 8) for a in (45, 135, 225, 315)])
    ol(c, clover, 3, shadow=False)
    body(c, clover, GREEN)


def g_sword(c, t, cols=STEEL):
    pts = rotp([(58, 96), (58, 24), (64, 8), (70, 24), (70, 96)], 64, 64, 45)
    blade = m_poly(c, pts)
    guard = m_rot_rect(c, 39.5, 88.5, 46, 12, 45, 4)
    grip = m_rot_rect(c, 29, 99, 10, 26, 45, 3)
    pommel = m_ellipse(c, 19, 109, 8)
    ol(c, union(blade, guard, grip, pommel))
    body(c, blade, cols)
    c.tint(WHITE, inter(m_poly(c, rotp([(62, 92), (62, 24), (64, 12), (64, 92)], 64, 64, 45)), blade), 0.45)
    body(c, guard, GOLD)
    body(c, grip, WOOD)
    body(c, pommel, GOLD)


def g_hide(c, t):
    back = m_ellipse(c, 70, 58, 46, 44)
    front = U.shield_mask(c)
    ol(c, union(back, front))
    body(c, back, GREY)
    c.paint(INK, sub(dilate(front, 3), front), 0.9)
    body(c, front, ((206, 214, 224), (110, 122, 140)))
    for (x, y, r) in ((44, 44, 8), (78, 56, 6), (56, 82, 7)):
        c.tint(darken(GREY[1], 0.2), m_ellipse(c, x, y, r, r * 0.6), 0.5)


def g_chestplate(c, t, cols=STEEL):
    plate = roundify(m_poly(c, [(20, 26), (44, 14), (64, 26), (84, 14), (108, 26), (102, 64), (94, 110), (64, 120), (34, 110), (26, 64)]), 3)
    ol(c, plate)
    body(c, plate, cols)
    c.paint(INK, m_rrect(c, 62.5, 30, 65.5, 114, 1), 0.5)
    for x in (40, 88):
        c.paint(GOLD[1], m_ellipse(c, x, 40, 5))
    c.tint(WHITE, inter(m_rrect(c, 30, 30, 58, 70, 10), plate), 0.2)


def g_flame(c, t, cols=((255, 236, 120), (232, 70, 30))):
    k = math.sin(t * 2 * math.pi)
    outer = roundify(m_poly(c, [(64, 6 + k * 4), (84, 40), (100, 30 - k * 3), (110, 70), (96, 110), (64, 122), (32, 110), (18, 70), (30, 36), (44, 52)]), 4)
    inner = roundify(m_poly(c, [(64, 46 - k * 3), (80, 76), (78, 104), (64, 112), (50, 104), (48, 78)]), 3)
    glow(c, outer, 6, (255, 140, 40), 0.5)
    ol(c, outer)
    body(c, outer, cols)
    c.paint((255, 248, 200), inner, 0.95)


def g_boot(c, t):
    flap = 5 * math.sin(t * 2 * math.pi)
    boot = roundify(m_poly(c, [(40, 14), (78, 14), (78, 80), (112, 92), (114, 112), (36, 112)]), 3)
    wing = roundify(m_poly(c, [(76, 40), (120, 20 - flap), (112, 36 - flap), (122, 46 - flap), (106, 56), (114, 64), (78, 66)]), 2)
    ol(c, union(boot, wing))
    body(c, wing, ((255, 255, 255), (196, 214, 236)))
    body(c, boot, ORANGE)
    sole = inter(m_rrect(c, 30, 102, 120, 114, 0), boot)
    c.paint(darken(ORANGE[1], 0.4), sole, 0.9)
    c.paint(CREAM[0], inter(m_rrect(c, 38, 14, 80, 26, 0), boot), 0.9)


def g_rings(c, t):
    k = t
    ms = []
    for i in range(3):
        r = 16 + ((i + k) % 3) * 16
        ms.append(ring(c, 64, 64, r, 7))
    dot = m_ellipse(c, 64, 64, 10)
    m = union(*ms, dot)
    ol(c, m, 3.5)
    body(c, union(*ms), TEAL, bevel=0)
    body(c, dot, GOLD, bevel=0)


def g_eye(c, t, cols=BLUE):
    eye = roundify(m_poly(c, [(8, 64), (36, 32), (64, 24), (92, 32), (120, 64), (92, 96), (64, 104), (36, 96)]), 6)
    ol(c, eye)
    body(c, eye, ((255, 255, 255), (220, 228, 240)))
    look = 6 * math.sin(t * 2 * math.pi)
    iris = m_ellipse(c, 64 + look, 64, 26)
    c.paint(INK, dilate(iris, 1.5), 0.8)
    body(c, iris, cols, bevel=1)
    c.paint(INK, m_ellipse(c, 64 + look, 64, 11))
    c.paint(WHITE, m_ellipse(c, 57 + look, 56, 5), 0.9)


def g_cap(c, t, book=False):
    if book:
        bk = m_rrect(c, 18, 82, 110, 118, 6)
        ol(c, bk)
        body(c, bk, BLUE)
        c.paint(CREAM[0], inter(m_rrect(c, 24, 104, 104, 112, 2), bk))
    board = m_poly(c, [(8, 46), (64, 18), (120, 46), (64, 74)])
    cap = m_poly(c, [(32, 56), (96, 56), (92, 86), (36, 86)]) if not book else m_poly(c, [(32, 56), (96, 56), (92, 78), (36, 78)])
    tassel = m_line(c, [(96, 48), (106, 54), (106, 84)], 4)
    ol(c, union(board, cap, tassel))
    body(c, cap, DARK)
    body(c, board, DARK)
    c.paint(GOLD[1], tassel)
    c.paint(GOLD[0], m_ellipse(c, 64, 46, 5))


def g_leech(c, t):
    d = roundify(union(m_ellipse(c, 64, 78, 38), m_poly(c, [(64, 6), (98, 62), (30, 62)])), 2)
    ol(c, d)
    body(c, d, RED)
    h = heart_mask(c, 64, 80, 0.5)
    c.paint(WHITE, h, 0.9)
    spec(c, 46, 66, 6, 12, 0.5)


def g_bag(c, t):
    sack = roundify(union(m_ellipse(c, 64, 84, 46, 38), m_poly(c, [(44, 50), (84, 50), (96, 70), (32, 70)])), 3)
    neck = m_rrect(c, 46, 36, 82, 52, 6)
    top = roundify(m_poly(c, [(40, 14), (64, 30), (88, 14), (84, 40), (44, 40)]), 3)
    ol(c, union(sack, neck, top))
    body(c, union(sack, top), WOOD)
    body(c, neck, RED)
    r = roundify(m_poly(c, [(64, 66), (84, 88), (64, 110), (44, 88)]), 2)
    c.paint(INK, dilate(r, 2), 0.8)
    body(c, r, ORANGE, bevel=0)


def g_tower_shield(c, t):
    sh = roundify(m_poly(c, [(22, 12), (106, 12), (106, 86), (64, 122), (22, 86)]), 5)
    ol(c, sh)
    body(c, sh, STEEL)
    inner = erode(sh, 9)
    body(c, inner, BLUE)
    for x in (34, 94):
        for y in (24, 74):
            c.paint(GOLD[1], m_ellipse(c, x, y, 4))
    c.paint(lighten(BLUE[0], 0.4), inter(m_rrect(c, 58, 20, 70, 108, 3), inner), 0.8)
    c.paint(lighten(BLUE[0], 0.4), inter(m_rrect(c, 30, 44, 98, 56, 3), inner), 0.8)


def g_fist(c, t):
    sym = U.sym_fist(c)
    ol(c, sym)
    body(c, sym, ((255, 214, 170), (214, 140, 96)))
    U.fist_details(c)
    k = math.sin(t * 2 * math.pi)
    for (x0, y0, x1, y1) in ((14, 30, 26, 40), (10, 60, 24, 62), (14, 92, 26, 84)):
        s = m_line(c, [(x0, y0 + k), (x1, y1 + k)], 4)
        c.paint(GOLD[1], s)


def g_meteor(c, t):
    k = t * 3
    tail = roundify(m_poly(c, [(8, 12), (78, 56), (60, 76)]), 3)
    tail2 = roundify(m_poly(c, [(30, 6), (84, 48), (76, 56)]), 2)
    rock = roundify(m_poly(c, poly_star(80, 82, 34, 28, 7, k * 20)), 3)
    glow(c, union(tail, tail2), 5, (255, 140, 40), 0.6)
    ol(c, union(tail, tail2, rock))
    c.paint(vgrad(c, [(0, (255, 240, 140)), (1, (240, 90, 30))], 6, 80), union(tail, tail2))
    body(c, rock, ((176, 150, 140), (96, 70, 66)))
    for (x, y, r) in ((70, 76, 6), (90, 92, 5), (88, 70, 3.5)):
        c.tint(darken((96, 70, 66), 0.3), m_ellipse(c, x, y, r), 0.7)


def g_overdrive(c, t):
    g_cog(c, t, ORANGE, 58, 70, 44, 8)
    bolt = roundify(m_poly(c, [(92, 4), (70, 52), (86, 52), (74, 96), (112, 40), (96, 40), (110, 4)]), 1.5)
    ol(c, bolt, 3.5)
    body(c, bolt, GOLD)


def g_dome(c, t):
    ground = m_rrect(c, 8, 98, 120, 112, 6)
    dome = m_ellipse(c, 64, 100, 56, 70)
    dome = inter(dome, (c.Y < 100).astype(F32))
    glow(c, dome, 4, (120, 220, 255), 0.25)
    rim = sub(dome, erode(dome, 5))
    ol(c, ground, 3.5)
    body(c, ground, GREEN)
    c.paint((120, 210, 255), dome, 0.35)
    c.paint(INK, rim, 0.25)
    body(c, rim, TEAL, rim=False, bevel=0)
    for x in (48, 80):
        e = m_ellipse(c, x, 84, 12, 13)
        ol(c, e, 2.5, shadow=False)
        body(c, e, GREY)
    sh = m_poly(c, [(64, 40), (78, 46), (74, 64), (64, 70), (54, 64), (50, 46)])
    ol(c, sh, 2.5, shadow=False)
    body(c, sh, GOLD)


def g_swap(c, t):
    k = 4 * math.sin(t * 2 * math.pi)
    top = roundify(union(m_rrect(c, 14, 30 + k * 0, 94, 48, 6), m_poly(c, [(86, 16), (118, 39), (86, 62)])), 2)
    bot = roundify(union(m_rrect(c, 34, 80, 114, 98, 6), m_poly(c, [(42, 66), (10, 89), (42, 112)])), 2)
    top = shift(top, k, 0)
    bot = shift(bot, -k, 0)
    ol(c, union(top, bot))
    body(c, top, ORANGE)
    body(c, bot, ((255, 255, 255), (196, 214, 236)))


def g_amulet(c, t):
    chain = m_arc(c, 64, 34, 34, 200, 340, 5)
    gemm = m_poly(c, [(64, 50), (92, 78), (64, 120), (36, 78)])
    setting = dilate(gemm, 5)
    ol(c, union(chain, setting))
    body(c, chain, GOLD, rim=False, bevel=0)
    body(c, setting, GOLD)
    body(c, gemm, PURPLE, bevel=0)
    c.tint(WHITE, inter(m_poly(c, [(64, 50), (36, 78), (64, 78)]), gemm), 0.35)
    spec(c, 56, 70, 4, 6, 0.8)


def g_dice_free_reroll(c, t):
    # a token card with cycling arrows (reroll tokens; nothing random is sold)
    card = m_rrect(c, 22, 14, 106, 114, 14)
    ol(c, card)
    body(c, card, BLUE)
    g_cycle(c, t, CREAM, coin=False)


def g_elephant_star(c, t):
    U.elephant_head(c, 60, 66, 0.82)
    mini_badge(c, "star", GOLD, 100, 26, 18)


def g_elephant_crown(c, t):
    U.elephant_head(c, 64, 72, 0.78)
    cr = roundify(m_poly(c, [(40, 34), (40, 14), (52, 24), (64, 6), (76, 24), (88, 14), (88, 34)]), 1.5)
    ol(c, cr, 3, shadow=False)
    body(c, cr, GOLD)


def g_cheese_pile(c, t, size=1):
    if size >= 3:
        coins = [(30, 104), (98, 106), (64, 112)]
        for x, y in coins:
            m = m_ellipse(c, x, y, 18, 9)
            ol(c, m, 3, shadow=False)
            body(c, m, GOLD, bevel=0)
    src = U.icon_golden_cheese() if size >= 2 else None
    if src is not None:
        # paste the golden wedge drawing, scaled to the pile size
        img = src.image().resize((96 if size == 2 else 104, 96 if size == 2 else 104), Image.LANCZOS)
        return img
    m = roundify(m_poly(c, [(20, 96), (78, 40), (108, 70), (108, 104), (20, 112)]), 2)
    glow(c, m, 7, (255, 220, 90), 0.5)
    ol(c, m)
    body(c, m, ((255, 246, 160), (232, 160, 10)))
    for (x, y, r) in ((70, 88, 7), (92, 84, 5)):
        c.tint((204, 120, 0), m_ellipse(c, x, y, r), 0.85)
    sparkle(c, 30, 46, 11)


# ---------------------------------------------------------------- icon table
# key -> (glyph, anim, motion, glow colour). Keys are what UI/IconMap points at.

ICONS = [
    # --- menus (lobby dock, strips, tabs)
    ("hero", wrap(U.icon_elephant), "shine", "bob", (255, 220, 120)),
    ("bots", g_robot, "wave", "bob", (130, 220, 255)),
    ("shop", g_cart, "shine", "tilt", (255, 210, 90)),
    ("sound_on", g_sound_on, "wave", "pulse", (255, 200, 120)),
    ("sound_off", g_sound_off, "none", "none", (220, 220, 220)),
    ("settings", g_cog, "spin", "none", (220, 230, 240)),
    ("look_suit", g_elephant_star, "shine", "bob", (255, 220, 120)),
    ("look_avatar", g_smile, "shine", "bob", (255, 220, 120)),
    ("herd", g_elephant_crown, "shine", "bob", (255, 220, 120)),
    ("gems", g_gem, "twinkle", "pulse", (140, 210, 255)),
    ("ladder", g_ladder, "shine", "tilt", (255, 210, 140)),
    ("horn", g_horn, "wave", "tilt", (255, 220, 120)),
    ("daily", wrap(U.icon_gift), "twinkle", "tilt", (255, 150, 120)),
    ("featured", wrap(U.icon_star), "twinkle", "pulse", (255, 220, 100)),
    ("cosmetics", g_tophat, "shine", "tilt", (220, 170, 255)),
    ("passes", wrap(U.icon_pass), "shine", "tilt", (255, 210, 90)),
    ("golden", wrap(U.icon_golden_cheese), "twinkle", "pulse", (255, 220, 90)),
    ("boosts", wrap(U.icon_boost), "pulse", "pulse", (255, 214, 60)),
    ("herd_pass", lambda c, t: g_medal(c, t, GOLD, (GREEN, BLUE)), "shine", "tilt", (255, 220, 120)),
    ("cheese_shop", g_stall, "shine", "bob", (255, 200, 120)),
    ("contracts", wrap(U.icon_scroll), "shine", "tilt", (255, 230, 170)),
    ("challenges", g_medal, "shine", "tilt", (255, 220, 120)),
    ("mousepedia", wrap(U.icon_book), "shine", "tilt", (140, 200, 255)),
    ("levels", g_levelup, "pulse", "bob", (150, 240, 130)),
    ("boards", wrap(U.icon_trophy), "twinkle", "pulse", (255, 220, 100)),
    ("perks", g_tree, "shine", "tilt", (150, 240, 130)),
    ("prestige", g_crown, "twinkle", "pulse", (255, 220, 100)),
    ("abilities", g_burst, "spin", "pulse", (255, 190, 90)),
    ("skins", g_palette, "shine", "tilt", (255, 190, 160)),
    ("ranks", g_chevrons, "pulse", "bob", (255, 200, 90)),
    ("whats_left", g_clipboard, "shine", "tilt", (255, 230, 170)),
    ("tools", g_tools, "shine", "tilt", (220, 230, 240)),
    ("fx", g_sparkles, "twinkle", "pulse", (255, 230, 120)),
    ("decor", g_flower, "shine", "tilt", (255, 180, 200)),
    ("filter_all", g_grid, "shine", "none", (255, 230, 170)),
    ("hats", lambda c, t: g_tophat(c, t, PURPLE, GOLD), "shine", "tilt", (220, 170, 255)),
    ("trails", g_trail, "twinkle", "bob", (190, 170, 255)),
    ("tints", g_drop, "shine", "bob", (140, 200, 255)),
    ("owned", g_check, "shine", "pulse", (150, 240, 130)),
    ("rinds", g_rind, "shine", "pulse", (255, 190, 90)),
    ("whey", g_milk, "shine", "bob", (200, 230, 255)),
    # --- Robux passes / products (Config/Monetization keys, via UI/IconMap)
    ("vip", lambda c, t: g_crown(c, t, PURPLE), "twinkle", "pulse", (220, 170, 255)),
    ("double_xp", lambda c, t: (wrap(U.icon_star)(c, t), mini_badge(c, "two", BLUE, 100, 100, 19)), "twinkle", "pulse", (140, 200, 255)),
    ("herd_leader", lambda c, t: g_flag(c, t, GOLD), "wave", "none", (255, 220, 120)),
    ("founders", g_shield, "shine", "pulse", (255, 220, 120)),
    ("wardrobe", g_wardrobe, "shine", "tilt", (220, 170, 255)),
    ("wardrobe_plus", lambda c, t: g_wardrobe(c, t, True), "shine", "tilt", (220, 170, 255)),
    ("skins_gilded", g_brush, "twinkle", "tilt", (255, 220, 100)),
    ("skins_neon", lambda c, t: g_brush(c, t, MAGENTA, True), "pulse", "tilt", (255, 120, 230)),
    ("golden_s", lambda c, t: g_cheese_pile(c, t, 1), "twinkle", "pulse", (255, 220, 90)),
    ("golden_m", lambda c, t: g_cheese_pile(c, t, 2), "twinkle", "pulse", (255, 220, 90)),
    ("golden_l", lambda c, t: g_cheese_pile(c, t, 3), "twinkle", "pulse", (255, 220, 90)),
    ("second_wind", g_heart_wings, "wave", "bob", (255, 150, 140)),
    ("cheese_rush", g_cheese_rush, "wave", "none", (255, 210, 90)),
    ("cheese_feast", g_plate, "shine", "bob", (255, 210, 90)),
    ("respec", g_cycle, "spin", "none", (220, 170, 255)),
    ("starter_pack", g_box, "shine", "tilt", (255, 200, 140)),
    ("emotes", g_bubble, "shine", "bob", (200, 230, 255)),
    ("cheese_club", g_card, "shine", "tilt", (130, 240, 222)),
    ("reroll", g_dice_free_reroll, "spin", "none", (140, 200, 255)),
    # --- Cheese Shop talents (Config/Talents) that have no rank twin
    ("magnet", g_magnet, "wave", "tilt", (255, 150, 140)),
    ("cheese_nose", g_sniff, "wave", "none", (200, 236, 160)),
    ("lucky_tusk", g_tusk, "twinkle", "tilt", (150, 240, 130)),
    # --- V-menu stat ranks (Config/RunShop.RANKS)
    ("might", g_fist, "wave", "pulse", (255, 160, 120)),
    ("hide", g_hide, "shine", "none", (220, 230, 240)),
    ("plating", g_chestplate, "shine", "none", (220, 230, 240)),
    ("mending", g_heart_plus, "pulse", "pulse", (255, 150, 140)),
    ("frenzy", g_flame, "wave", "none", (255, 160, 60)),
    ("stride", g_boot, "wave", "bob", (255, 200, 120)),
    ("reach", g_rings, "wave", "none", (130, 240, 222)),
    ("focus", g_eye, "wave", "none", (140, 200, 255)),
    ("quick_study", lambda c, t: (wrap(U.icon_book)(c, t), mini_badge(c, "up", GREEN, 100, 100, 18)), "twinkle", "tilt", (140, 200, 255)),
    # --- whey stall buffs (Config/RunShop.BUFFS) + the Class Stall
    ("rush", g_clock, "spin", "none", (150, 240, 130)),
    ("thick_skin", lambda c, t: g_shield(c, t, GREEN, False), "shine", "none", (150, 240, 130)),
    ("keen", lambda c, t: g_eye(c, t, RED), "wave", "none", (255, 150, 140)),
    ("leech", g_leech, "pulse", "pulse", (255, 120, 110)),
    ("bloom", g_flower, "pulse", "pulse", (255, 180, 200)),
    ("greed", g_bag, "twinkle", "tilt", (255, 190, 90)),
    ("scholar", lambda c, t: g_cap(c, t, True), "shine", "bob", (180, 170, 255)),
    ("bulwark", g_tower_shield, "shine", "none", (140, 200, 255)),
    ("rally", g_flag, "wave", "none", (255, 150, 140)),
    ("class_buff", lambda c, t: g_medal(c, t, ORANGE, (RED, GOLD)), "twinkle", "pulse", (255, 190, 90)),
    # --- Big Cheese Altar ultimates (Config/RunShop.ULTIMATES) + the Swap Stand
    ("titan", lambda c, t: (g_fist(c, t), mini_badge(c, "up", RED, 102, 26, 18)), "pulse", "pulse", (255, 160, 120)),
    ("cataclysm", g_meteor, "spin", "bob", (255, 140, 40)),
    ("overdrive", g_overdrive, "spin", "none", (255, 214, 60)),
    ("herdguard", g_dome, "pulse", "pulse", (130, 220, 255)),
    ("swap", g_swap, "wave", "none", (255, 200, 120)),
    # --- gear slots (UI/GearInfo.SLOTS)
    ("weapon", g_sword, "shine", "tilt", (220, 230, 240)),
    ("armor", lambda c, t: g_chestplate(c, t, ((180, 200, 230), (80, 100, 150))), "shine", "none", (140, 200, 255)),
    ("trinket", g_amulet, "twinkle", "bob", (220, 170, 255)),
]

SPIN_LIKE = {"spin", "wave"}
FPS = {"shine": 10, "twinkle": 6, "pulse": 6, "spin": 8, "wave": 5, "none": 0}
HOLD = {"shine": 3.2, "twinkle": 0, "pulse": 0, "spin": 0, "wave": 0, "none": 0}


# ---------------------------------------------------------------- rendering


def render_glyph(glyph, t):
    c = Canvas(CELL, CELL)
    out = glyph(c, t)
    if isinstance(out, Image.Image):
        # a glyph may return a ready image (pasted centred over what it drew)
        base = c.image()
        x = (CELL - out.size[0]) // 2
        y = (CELL - out.size[1]) // 2 - 6
        base.alpha_composite(out, (x, max(0, y)))
        return base
    return c.image()


def arr(img):
    return np.asarray(img, dtype=np.float32) / 255.0


def to_img(a):
    a = np.clip(np.round(a * 255), 0, 255).astype(np.uint8)
    a[a[..., 3] == 0] = 0
    return Image.fromarray(a, "RGBA")


def fx_shine(img, k):
    """Frame k (1..3): a soft diagonal light band across the icon."""
    a = arr(img)
    n = CELL
    ys, xs = np.mgrid[0:n, 0:n].astype(np.float32)
    pos = (-0.15 + 0.55 * k) * 2 * n  # x + y of the band centre
    band = np.exp(-(((xs + ys) - pos) / (n * 0.12)) ** 2)
    alpha = a[..., 3]
    s = band * np.clip((alpha - 0.6) / 0.4, 0, 1) * 0.6
    a[..., :3] = a[..., :3] * (1 - s[..., None]) + s[..., None]
    return to_img(a)


def fx_pulse(img, k, color):
    amount = (0.0, 0.5, 1.0, 0.5)[k]
    if amount <= 0:
        return img
    alpha = img.getchannel("A")
    halo = alpha.filter(ImageFilter.GaussianBlur(7))
    halo = halo.point(lambda v: int(min(255, v * 1.7 * amount)))
    layer = Image.new("RGBA", img.size, color + (0,))
    layer.putalpha(halo)
    return Image.alpha_composite(layer, img)


def fx_twinkle(img, k, seed):
    c = Canvas(CELL, CELL)
    rng = np.random.default_rng(seed)
    spots = [(rng.uniform(14, 40), rng.uniform(14, 40)), (rng.uniform(90, 116), rng.uniform(18, 46)), (rng.uniform(86, 114), rng.uniform(88, 114))]
    for i, (x, y) in enumerate(spots):
        ph = (k + i * 1.3) % 4 / 4
        r = 4 + 10 * math.sin(ph * math.pi)
        if r > 5:
            sparkle(c, x, y, r, 0.95)
    return Image.alpha_composite(img, c.image())


def frames_for(key, glyph, anim, color, seed):
    if anim in SPIN_LIKE:
        return [render_glyph(glyph, k / FRAMES) for k in range(FRAMES)]
    base = render_glyph(glyph, 0.0)
    out = [base]
    for k in range(1, FRAMES):
        if anim == "shine":
            out.append(fx_shine(base, k))
        elif anim == "pulse":
            out.append(fx_pulse(base, k, color))
        elif anim == "twinkle":
            out.append(fx_twinkle(base, k, seed))
        else:
            out.append(base)
    if anim == "twinkle":
        out[0] = fx_twinkle(base, 0, seed)
    return out


def glow_sprite():
    n = CELL
    ys, xs = np.mgrid[0:n, 0:n].astype(np.float32)
    d = np.hypot(xs - n / 2 + 0.5, ys - n / 2 + 0.5) / (n / 2)
    a = np.clip(1 - d, 0, 1) ** 2.2
    out = np.zeros((n, n, 4), np.float32)
    out[..., :3] = 1
    out[..., 3] = a * 0.9
    return to_img(out)


def build():
    keys = [k for k, *_ in ICONS]
    assert len(keys) == len(set(keys)), "duplicate icon key"
    n_atlas = math.ceil(len(ICONS) / SLOTS)
    atlases = [Image.new("RGBA", (ATLAS, ATLAS), (0, 0, 0, 0)) for _ in range(n_atlas)]
    glow = glow_sprite()
    entries = {}
    for i, (key, glyph, anim, motion, color) in enumerate(ICONS):
        ai, slot = divmod(i, SLOTS)
        row, col = divmod(slot, PER_ROW)
        x0, y0 = col * CELL * FRAMES, row * CELL
        frames = frames_for(key, glyph, anim, color, 1000 + i)
        for k, f in enumerate(frames):
            atlases[ai].alpha_composite(f, (x0 + k * CELL, y0))
        entries[key] = {
            "atlas": f"icon_atlas_{ai + 1}",
            "x": x0,
            "y": y0,
            "frames": 1 if anim == "none" else FRAMES,
            "anim": anim,
            "motion": motion,
            "fps": FPS[anim],
            "hold": HOLD[anim],
            "glow": list(color),
        }
        print(f"  {key:14s} -> icon_atlas_{ai + 1} ({x0},{y0}) {anim}/{motion}")
    gx, gy = (PER_ROW - 1) * CELL * FRAMES, (ROWS - 1) * CELL
    for a in atlases:
        a.alpha_composite(glow, (gx, gy))
    return atlases, entries, (gx, gy)


def write_luau(entries, glow_xy, n_atlas):
    L = [
        "--!strict",
        "-- GENERATED by scripts/make-icons.py: do not edit by hand.",
        "-- Animated icon atlases (assets/icons/icon_atlas_*.png, uploaded as the",
        "-- manifest's icon_atlas_* Images). Each icon's frames sit side by side from",
        "-- (x, y), `cell` px square; UI/AnimatedIcon steps them with ImageRectOffset.",
        "return {",
        f"\tcell = {CELL},",
        f"\tsize = {ATLAS},",
        f"\tglow = {{ x = {glow_xy[0]}, y = {glow_xy[1]} }},",
        "\tatlases = { " + ", ".join(f'"icon_atlas_{i + 1}"' for i in range(n_atlas)) + " },",
        "\ticons = {",
    ]
    for key in sorted(entries):
        e = entries[key]
        g = e["glow"]
        L.append(
            f'\t\t["{key}"] = {{ atlas = "{e["atlas"]}", x = {e["x"]}, y = {e["y"]}, frames = {e["frames"]}, '
            f'anim = "{e["anim"]}", motion = "{e["motion"]}", fps = {e["fps"]}, hold = {e["hold"]}, '
            f"glow = {{ {g[0]}, {g[1]}, {g[2]} }} }},"
        )
    L += ["\t},", "}", ""]
    with open(ATLAS_LUAU, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L))


def write_manifest(n_atlas):
    """Adds / refreshes the icon_atlas_* Image entries (only that prefix: other icon_ sets, e.g. icon_cos_atlas_*, are untouched)."""
    data = json.load(open(MANIFEST, encoding="utf-8"))
    wrapped = isinstance(data, dict)
    entries = data.get("assets", []) if wrapped else data
    want = [f"icon_atlas_{i + 1}" for i in range(n_atlas)]
    out = [e for e in entries if not str(e.get("name", "")).startswith("icon_atlas_")]
    for name in want:
        out.append(
            {
                "name": name,
                "path": f"../icons/{name}.png",
                "type": "Image",
                "description": f"Trunkfall animated UI icons: {name}",
            }
        )
    data = {"assets": out} if wrapped else out
    with open(MANIFEST, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")


def preview(atlases, path):
    w = ATLAS
    sheet = Image.new("RGBA", (w, w * len(atlases)), (236, 228, 214, 255))
    for i, a in enumerate(atlases):
        sheet.alpha_composite(a, (0, i * w))
    sheet.convert("RGB").save(path)
    print("preview ->", path)


def main(argv):
    atlases, entries, glow_xy = build()
    os.makedirs(OUT_DIR, exist_ok=True)
    keep = set()
    for i, a in enumerate(atlases):
        name = f"icon_atlas_{i + 1}.png"
        a.save(os.path.join(OUT_DIR, name), optimize=True)
        keep.add(name)
    for f in os.listdir(OUT_DIR):
        if f.startswith("icon_atlas_") and f.endswith(".png") and f not in keep:
            os.remove(os.path.join(OUT_DIR, f))
    write_luau(entries, glow_xy, len(atlases))
    write_manifest(len(atlases))
    print(f"{len(entries)} icons in {len(atlases)} atlases -> {os.path.relpath(OUT_DIR, ROOT)}")
    if "--preview" in argv:
        i = argv.index("--preview")
        out = argv[i + 1] if i + 1 < len(argv) else "."
        os.makedirs(out, exist_ok=True)
        preview(atlases, os.path.join(out, "icons_sheet.png"))


if __name__ == "__main__":
    main(sys.argv[1:])
