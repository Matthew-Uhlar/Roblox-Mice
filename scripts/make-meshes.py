#!/usr/bin/env python3
"""Procedural "chunky toy" meshes for Trunkfall (no paid generation).

    pip install -r scripts/requirements-meshes.txt
    python3 scripts/make-meshes.py                 # build every model
    python3 scripts/make-meshes.py mouse_chonk     # only some (name prefixes ok)
    python3 scripts/make-meshes.py --sheet out.png # also render a contact sheet
    python3 scripts/make-meshes.py --list          # names and budgets
    python3 scripts/make-meshes.py --color-mode vertex   # COLOR_0 instead of texture

Writes assets/models/meshes/<name>.glb (Roblox studs, Y up, facing -Z, feet at
Y = 0, centred on X/Z; one mesh, one material with a palette baseColorTexture)
and assets/models/meshes/meshes.json (per model: triangles, bytes, size and the
hitbox `radius` the model was designed at, which the runtime should set as the
template's Radius attribute; the importer drops glTF extras). Then add new names
to assets/models/manifest.json with --manifest.

The models follow the part models in src/client/Visuals/{MouseModels,
BossModels,ChampionModels}.luau and src/server/Visuals/BotModel.luau (same ids,
proportions and colours) and the prompts in assets/models/PLAN.md. All designs
are our own. Output is deterministic. The modelling kit is scripts/meshkit.py.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from meshkit import (  # noqa: E402
    Model,
    capsule,
    cone,
    cyl,
    ell,
    lerp_c,
    plane,
    rbox,
    rgb,
    rot,
    sphere,
    sym,
    torus,
    tube,
    union,
)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "assets", "models", "meshes")
MANIFEST = os.path.join(ROOT, "assets", "models", "manifest.json")

# shared palette (docs/STYLE.md + the part models)
WHITE = rgb(255, 255, 255)
EYE = rgb(26, 20, 26)
PINK = rgb(246, 170, 186)
PINK_DARK = rgb(232, 112, 138)
GOLD = rgb(255, 196, 40)
CHEESE = rgb(255, 201, 60)
MOUTH = rgb(120, 40, 50)
WOOD = rgb(130, 86, 48)

BUDGET_MOUSE = 1500
BUDGET_BOSS = 8000
BUDGET_CHAMP = 8000
BUDGET_HERO = 5000

REGISTRY: dict[str, tuple[callable, int, str]] = {}


def model(name, budget, kind):
    def deco(fn):
        REGISTRY[name] = (fn, budget, kind)
        return fn

    return deco


# shared bits ----------------------------------------------------------------


def bead_eyes(m: Model, x, y, z, r, yaw=12.0, glint=True, color=EYE, white=None):
    """Glossy bead eyes (+X side mirrored): optional white sclera, dark bead,
    a big and a small highlight."""
    for s in (-1, 1):
        R = rot(0, -s * yaw, 0)
        c = np.array([s * x, y, z])
        fwd = R @ np.array([0, 0, -1.0])
        if white is not None:
            m.ball(white, c, [r * 1.25, r * 1.45, r * 0.8], R, subdiv=2)
            c = c + fwd * r * 0.45
        m.ball(color, c, [r, r * 1.2, r * 0.7], R, subdiv=2 if white is not None else 1)
        if glint:
            m.ball(WHITE, c + fwd * r * 0.62 + np.array([-s * r * 0.3, r * 0.4, 0]), r * 0.32, subdiv=0)
            m.ball(WHITE, c + fwd * r * 0.62 + np.array([s * r * 0.25, -r * 0.4, 0]), r * 0.15, subdiv=0)


def big_eyes(m: Model, x, y, z, r, iris, yaw=10.0, pupil=EYE, sclera=WHITE, depth=0.75):
    """Cartoon eyes for bosses/champions: white, coloured iris, dark pupil,
    two glints (+X side mirrored)."""
    for s in (-1, 1):
        R = rot(0, -s * yaw, 0)
        c = np.array([s * x, y, z])
        fwd = R @ np.array([0, 0, -1.0])
        m.ball(sclera, c, [r, r * 1.12, r * depth], R, subdiv=2)
        ci = c + fwd * r * depth * 0.62
        m.ball(iris, ci, [r * 0.62, r * 0.7, r * 0.42], R, subdiv=2)
        cp = ci + fwd * r * 0.2
        m.ball(pupil, cp, [r * 0.34, r * 0.4, r * 0.3], R, subdiv=1)
        m.ball(WHITE, cp + fwd * r * 0.2 + np.array([-s * r * 0.2, r * 0.25, 0]), r * 0.17, subdiv=1)
        m.ball(WHITE, cp + fwd * r * 0.18 + np.array([s * r * 0.18, -r * 0.2, 0]), r * 0.08, subdiv=0)


def cheese_wedge(c, size, yaw=0.0, holes=True):
    """A cheese wedge (rounded box cut by a slanted plane), as a list of
    (op, shape) for a group."""
    sx, sy, sz = size
    R = rot(0, yaw, 0)
    box = rbox(c, [sx / 2, sy / 2, sz / 2], r=min(sx, sy, sz) * 0.12, R=R)
    # slope: top falls toward local -Z
    n = R @ np.array([0, 1.0, -sy / sz * 1.0])
    n = n / np.linalg.norm(n)
    top = plane(n, float(np.asarray(c) @ n) + sy * 0.18)
    ops = [("add", box, 0.0), ("inter", top, sy * 0.08)]
    if holes:
        for hx, hy, hz, hr in ((0.5, 0.1, 0.2, 0.22), (-0.55, -0.15, -0.1, 0.18), (0.48, -0.3, -0.35, 0.14)):
            p = np.asarray(c) + R @ np.array([hx * sx / 2 * 2.05, hy * sy, hz * sz])
            ops.append(("sub", sphere(p, hr * min(sx, sz)), 0.04))
    return ops


def apply(g, ops):
    for op, s, k in ops:
        getattr(g, op)(s, k)
    return g


# mice -----------------------------------------------------------------------

LOOKS = {
    "mouse": dict(
        body=rgb(96, 62, 44),
        belly=rgb(236, 214, 186),
        bs=(1.6, 1.35, 1.85),
        hs=(1.45, 1.3, 1.3),
        ear=0.95,
        tail=1.0,
        legs=1.0,
        snout=1.0,
    ),
    "rat_runner": dict(
        body=rgb(84, 74, 76),
        belly=rgb(200, 186, 178),
        bs=(1.2, 1.05, 2.5),
        hs=(1.1, 1.0, 1.45),
        ear=0.7,
        tail=1.55,
        legs=1.3,
        snout=1.5,
    ),
    "chonk": dict(
        body=rgb(92, 64, 104),
        belly=rgb(232, 228, 240),
        bs=(2.2, 1.95, 2.15),
        hs=(1.5, 1.3, 1.25),
        ear=0.75,
        tail=0.7,
        legs=0.75,
        snout=0.8,
    ),
    "crumb_slinger": dict(
        body=rgb(132, 96, 62),
        belly=rgb(248, 230, 196),
        bs=(1.5, 1.3, 1.75),
        hs=(1.4, 1.28, 1.28),
        ear=1.0,
        tail=1.0,
        legs=1.0,
        snout=1.0,
    ),
    "fuse_mouse": dict(
        body=rgb(204, 96, 72),
        belly=rgb(248, 200, 170),
        bs=(1.55, 1.3, 1.8),
        hs=(1.4, 1.28, 1.28),
        ear=0.95,
        tail=1.0,
        legs=1.0,
        snout=1.0,
    ),
    "carrier": dict(
        body=rgb(255, 200, 64),
        belly=rgb(255, 244, 200),
        bs=(1.5, 1.3, 1.8),
        hs=(1.4, 1.28, 1.28),
        ear=1.0,
        tail=1.1,
        legs=1.1,
        snout=1.0,
    ),
}


def build_mouse(mid: str) -> Model:
    L = LOOKS[mid]
    m = Model("mouse_" + mid, BUDGET_MOUSE, radius=1.2)
    bx, by, bz = L["bs"]
    hx, hy, hz = L["hs"]
    hx, hy, hz = hx * 1.12, hy * 1.12, hz * 1.08  # chibi: a bit more head
    legH = 0.5 * L["legs"]
    bodyY = legH + by * 0.4
    ln = bz
    headZ = -ln / 2 - hz * 0.18
    headY = bodyY + by * 0.36 + hy * 0.14
    if mid == "rat_runner":
        headY -= 0.12  # leaning into the sprint
    fur, belly = L["body"], L["belly"]
    dark = lerp_c(fur, EYE, 0.28)
    lean = -8.0 if mid == "rat_runner" else 0.0

    body = m.group(fur, weight=1.0, min_tris=300)
    body.add(ell((0, bodyY, 0.1), (bx / 2, by / 2, bz / 2), rot(lean, 0, 0)))
    body.add(ell((0, headY, headZ), (hx / 2, hy / 2, hz / 2)), k=0.35)
    # rump bump and haunches
    body.add(sym(ell((bx * 0.26, bodyY - by * 0.08, ln * 0.22), (bx * 0.24, by * 0.3, bz * 0.22))), k=0.25)
    # legs: stubby, smooth-blended into the body
    for front in (-1, 1):
        z = front * ln * 0.27 + 0.05
        body.add(sym(capsule((bx * 0.27, bodyY - by * 0.1, z), (bx * 0.29, legH * 0.55, z - 0.05), 0.2 * max(1, L["legs"] * 0.85))), k=0.18)
    # cheeks (puffier on chonk)
    puff = 1.35 if mid == "chonk" else 1.0
    body.add(sym(ell((hx * 0.3, headY - hy * 0.12, headZ - hz * 0.16), (hx * 0.22 * puff, hy * 0.2 * puff, hz * 0.22))), k=0.15)

    # feet (darker paws)
    feet = m.group(dark, min_tris=110)
    for front in (-1, 1):
        z = front * ln * 0.27 + 0.05 - 0.1
        feet.add(sym(ell((bx * 0.29, 0.13, z), (0.22, 0.13, 0.3))))

    # belly patch + muzzle
    bel = m.group(belly, min_tris=90)
    bel.add(ell((0, bodyY - by * 0.06, 0.1 - bz * 0.2), (bx * 0.33, by * 0.36, bz * 0.36), rot(lean, 0, 0)))
    sn = L["snout"]
    mz = headZ - hz * 0.4 - 0.06 * sn
    bel.add(ell((0, headY - hy * 0.17, mz), (hx * 0.27, hy * 0.21, hz * 0.24 * sn)), k=0.05)
    # nose + teeth + mouth
    nose_z = mz - hz * 0.22 * sn
    m.ball(PINK_DARK, (0, headY - hy * 0.08, nose_z), [0.15, 0.12, 0.12], subdiv=1)
    teeth = m.group(WHITE, min_tris=24)
    teeth.add(rbox((0, headY - hy * 0.31, mz - hz * 0.14 * sn), (0.1, 0.08, 0.035), r=0.025))
    # blush
    m.sym_ball(PINK, (hx * 0.36, headY - hy * 0.13, headZ - hz * 0.37), [0.14, 0.08, 0.05], rot(0, -28, 0), subdiv=0)
    # eyes
    bead_eyes(m, hx * 0.21, headY + hy * 0.08, headZ - hz * 0.43, 0.15 if mid != "rat_runner" else 0.13)

    # ears: big round discs with pink insides
    e = L["ear"] * 1.08
    ec = np.array([hx * 0.36, headY + hy * 0.36 + e * 0.3, headZ + 0.12])
    R_ear = rot(-8, -14, -24)
    ears = m.group(lerp_c(fur, PINK, 0.15), min_tris=120)
    ears.add(sym(ell(ec, (e * 0.52, e * 0.5, 0.1), R_ear)))
    ears.add(sym(capsule(ec - np.array([0.1, e * 0.35, -0.05]), ec - np.array([0.15, e * 0.6, -0.05]), 0.14)), k=0.12)
    inner = m.group(PINK, min_tris=60)
    fwd = R_ear @ np.array([0, 0, -1.0])
    inner.add(sym(ell(ec + fwd * 0.055 + np.array([0, -0.03, 0]), (e * 0.37, e * 0.35, 0.06), R_ear)))

    # tail: a pink curl rising behind
    t = L["tail"]
    tz = ln / 2 + 0.05
    ty = bodyY + by * 0.02
    pts = [
        (0, ty, tz - 0.25),
        (0, ty - 0.12, tz + 0.45 * t),
        (0.06, ty + 0.05, tz + 0.95 * t),
        (0.12, ty + 0.5 * t, tz + 1.25 * t),
        (0.05, ty + 0.92 * t, tz + 1.12 * t),
        (-0.05, ty + 1.02 * t, tz + 0.88 * t),
    ]
    if mid == "rat_runner":  # long whip, low and straight
        pts = [(0, ty, tz - 0.25), (0, ty - 0.1, tz + 0.6 * t), (0.1, ty - 0.05, tz + 1.2 * t), (0.25, ty + 0.15, tz + 1.7 * t), (0.3, ty + 0.4, tz + 2.0 * t)]
    tail = m.group(PINK, min_tris=60)
    tail.add(tube(pts, list(np.linspace(0.14, 0.06, len(pts)))))

    extras_mouse(m, mid, L, dict(bodyY=bodyY, headY=headY, headZ=headZ, ln=ln, hx=hx, hy=hy, hz=hz, bx=bx, by=by, bz=bz))
    return m


def extras_mouse(m: Model, mid, L, F):
    bodyY, headY, headZ, ln = F["bodyY"], F["headY"], F["headZ"], F["ln"]
    hx, hy, hz, bx, by, bz = F["hx"], F["hy"], F["hz"], F["bx"], F["by"], F["bz"]
    back = np.array([0, bodyY + by * 0.45, 0.25])
    if mid == "rat_runner":
        red = rgb(225, 50, 45)
        band = m.group(red, min_tris=90)
        band.add(torus((0, headY + hy * 0.14, headZ + 0.02), hx * 0.47, 0.07, rot(-14, 0, 0)))
        band.add(tube([(0.05, headY + hy * 0.12, headZ + hz * 0.48), (0.25, headY + 0.02, headZ + hz * 0.85), (0.4, headY - 0.12, headZ + hz * 1.05)], [0.07, 0.07, 0.04]), k=0.05)
        band.add(tube([(-0.05, headY + hy * 0.12, headZ + hz * 0.48), (-0.15, headY - 0.08, headZ + hz * 0.8), (-0.2, headY - 0.3, headZ + hz * 0.95)], [0.07, 0.06, 0.04]), k=0.05)
    elif mid == "chonk":
        g = m.group(rgb(255, 205, 60), min_tris=120)
        apply(g, cheese_wedge((0, bodyY - 0.15, 0.1 - bz * 0.55), (1.25, 0.75, 0.9), yaw=180))
        # little paws hugging it
        paws = m.group(lerp_c(L["body"], EYE, 0.15), min_tris=40)
        paws.add(sym(ell((0.62, bodyY - 0.05, 0.1 - bz * 0.5), (0.2, 0.17, 0.22))))
    elif mid == "crumb_slinger":
        red = rgb(255, 90, 78)
        band = m.group(red, min_tris=70)
        band.add(torus((0, headY + hy * 0.16, headZ + 0.02), hx * 0.47, 0.075, rot(-14, 0, 0)))
        sack = m.group(red, min_tris=90)
        sack.add(ell(back + [0, 0.25, 0.25], (0.45, 0.42, 0.38)))
        sack.add(cone(back + [0, 0.55, 0.25], back + [0, 0.8, 0.25], 0.16, 0.1), k=0.08)
        tie = m.group(rgb(150, 110, 70), min_tris=30)
        tie.add(torus(back + [0, 0.62, 0.25], 0.13, 0.045))
        # crumbs peeking out
        for i, (dx, dz) in enumerate(((0.06, 0.0), (-0.07, 0.05), (0.0, -0.07))):
            m.ball(rgb(240, 200, 110), back + [dx, 0.86 + 0.02 * i, 0.25 + dz], 0.06, subdiv=0)
        # slingshot in the right paw, raised
        hand = np.array([0.62, bodyY + 0.15, -ln / 2 + 0.05])
        wood = m.group(WOOD, min_tris=80)
        top = hand + [0, 0.55, -0.1]
        wood.add(capsule(hand - [0, 0.1, 0], top, 0.065))
        wood.add(tube([top, top + [0.2, 0.18, 0], top + [0.24, 0.42, 0]], [0.06, 0.055, 0.05]), k=0.04)
        wood.add(tube([top, top + [-0.2, 0.18, 0], top + [-0.24, 0.42, 0]], [0.06, 0.055, 0.05]), k=0.04)
        band2 = m.group(rgb(240, 120, 110), min_tris=24)
        band2.add(capsule(top + [-0.24, 0.4, 0.0], top + [0.24, 0.4, 0.0], 0.03))
        paw = m.group(lerp_c(L["body"], EYE, 0.15), min_tris=30)
        paw.add(ell(hand + [0, 0.05, 0], (0.16, 0.16, 0.16)))
        paw.add(capsule(hand + [0, 0.05, 0], np.array([0.5, bodyY + 0.05, -ln / 2 + 0.3]), 0.12), k=0.08)
    elif mid == "fuse_mouse":
        bomb = back + [0, 0.45, 0.2]
        b = m.group(rgb(40, 38, 48), min_tris=160)
        b.add(sphere(bomb, 0.55))
        cap = m.group(rgb(110, 110, 122), min_tris=40)
        cap.add(cyl(bomb + [0, 0.55, 0], 0.22, 0.2, round_=0.04))
        fuse = m.group(rgb(150, 120, 80), min_tris=40)
        fp = [bomb + [0, 0.62, 0], bomb + [0.08, 0.82, 0.02], bomb + [0.22, 0.92, -0.04], bomb + [0.32, 0.96, -0.06]]
        fuse.add(tube(fp, [0.05, 0.045, 0.04, 0.035]))
        spark = fp[-1] + [0.04, 0.04, 0]
        sp = m.group(rgb(255, 200, 60), min_tris=60)
        sp.add(sphere(spark, 0.12))
        for d in ((1, 0, 0), (-1, 0.2, 0), (0, 1, 0), (0.6, 0.6, 0), (-0.5, 0.7, 0.3), (0.3, 0.2, -1), (0, 0.3, 1)):
            d = np.array(d, dtype=float)
            d /= np.linalg.norm(d)
            sp.add(cone(spark, spark + d * 0.24, 0.07, 0.015), k=0.03)
        m.ball(rgb(255, 120, 40), spark, 0.09, subdiv=1)
        m.ball(WHITE, bomb + [-0.22, 0.25, -0.38], 0.1, subdiv=1)  # bomb shine
    elif mid == "carrier":
        sack = back + [0, 0.42, 0.25]
        s = m.group(rgb(150, 100, 60), min_tris=120)
        s.add(ell(sack, (0.55, 0.5, 0.48)))
        s.add(cone(sack + [0, 0.4, 0], sack + [0, 0.72, 0], 0.2, 0.13), k=0.1)
        s.add(ell(sack + [0, 0.78, 0], (0.2, 0.08, 0.2)), k=0.08)
        tie = m.group(rgb(255, 210, 70), min_tris=40)
        tie.add(torus(sack + [0, 0.55, 0], 0.17, 0.05))
        coins = m.group(GOLD, min_tris=40)
        coins.add(cyl(sack + [0.25, 0.86, -0.05], 0.06, 0.15, rot(70, 0, 20), round_=0.02))
        coins.add(cyl(sack + [-0.2, 0.84, 0.1], 0.06, 0.13, rot(-60, 0, -10), round_=0.02))
        m.ball(rgb(255, 250, 200), sack + [0.32, 0.25, -0.38], 0.06, subdiv=0)
        m.ball(rgb(255, 250, 200), sack + [-0.38, 0.1, -0.3], 0.05, subdiv=0)
        # smug brows
        brow = m.group(lerp_c(L["body"], rgb(160, 90, 20), 0.6), min_tris=24)
        brow.add(sym(capsule((hx * 0.12, headY + hy * 0.3, headZ - hz * 0.42), (hx * 0.32, headY + hy * 0.24, headZ - hz * 0.37), 0.04)))


for _mid in LOOKS:
    REGISTRY["mouse_" + _mid] = ((lambda mid: (lambda: build_mouse(mid)))(_mid), BUDGET_MOUSE, "mouse")


# bosses ---------------------------------------------------------------------
# Designed at unit footprint radius (Radius = 1), like BossModels (scaled to
# the boss hitbox at run time), facing -Z.

STEEL = rgb(186, 194, 206)


def boss(name):
    return model("boss_" + name, BUDGET_BOSS, "boss")


def _rng(seed):
    return np.random.default_rng(seed)


@boss("giant_tree")
def b_giant_tree():
    m = Model("boss_giant_tree", BUDGET_BOSS, radius=1.0)
    bark = rgb(110, 78, 46)
    bark_dark = lerp_c(bark, rgb(24, 20, 24), 0.3)
    t = m.group(bark, min_tris=1400)
    t.add(cone((0, 0.15, 0), (0, 2.3, 0), 0.72, 0.55))
    t.inter(plane((0, -1, 0), -0.02), k=0.03)
    for i in range(6):  # flared roots
        a = math.radians(i * 60 + 30)
        d = np.array([math.sin(a), 0, math.cos(a)])
        t.add(tube([d * 0.35 + [0, 0.7, 0], d * 0.85 + [0, 0.22, 0], d * 1.15 + [0, 0.1, 0]], [0.28, 0.2, 0.12]), k=0.2)
    # branch arms raised, angry
    for s in (-1, 1):
        t.add(tube([(s * 0.45, 1.75, 0), (s * 1.0, 2.0, -0.1), (s * 1.35, 2.45, -0.25)], [0.22, 0.16, 0.12]), k=0.15)
        t.add(tube([(s * 1.0, 2.0, -0.1), (s * 1.25, 1.75, -0.2)], [0.09, 0.06]), k=0.05)
    # carved face: eye sockets + mouth hollow
    t.sub(sym(ell((0.27, 1.72, -0.66), (0.22, 0.19, 0.2))), k=0.05)
    t.sub(ell((0, 1.2, -0.66), (0.3, 0.17, 0.2)), k=0.06)
    # bark ridges
    ridges = m.group(bark_dark, min_tris=500)
    for i in range(10):
        a = math.radians(i * 36 + 8)
        if abs(((i * 36 + 8) % 360) - 180) < 40:
            continue  # keep the face clear
        d = np.array([math.sin(a), 0, math.cos(a)])
        ridges.add(capsule(d * 0.66 + [0, 0.45, 0], d * 0.56 + [0, 2.1, 0], 0.07))
    # angry brows
    ridges.add(sym(capsule((0.1, 1.98, -0.7), (0.44, 1.9, -0.6), 0.07)))
    # glowing eyes and mouth
    glow = rgb(255, 210, 70)
    m.sym_ball(glow, (0.27, 1.71, -0.56), [0.17, 0.15, 0.1], subdiv=2)
    m.sym_ball(rgb(60, 30, 20), (0.27, 1.7, -0.645), [0.06, 0.08, 0.03], subdiv=1)
    m.sym_ball(rgb(255, 250, 220), (0.22, 1.77, -0.65), 0.04, subdiv=0)
    mouth = m.group(rgb(60, 30, 20), min_tris=80)
    mouth.add(ell((0, 1.2, -0.55), (0.27, 0.14, 0.12)))
    m.ball(rgb(240, 230, 200), (0.1, 1.29, -0.63), [0.05, 0.05, 0.03], subdiv=1)
    m.ball(rgb(240, 230, 200), (-0.12, 1.11, -0.63), [0.05, 0.05, 0.03], subdiv=1)
    # leafy mittens
    leaf = rgb(84, 158, 62)
    mit = m.group(leaf, min_tris=200)
    for s in (-1, 1):
        mit.add(sphere((s * 1.4, 2.55, -0.28), 0.24))
        mit.add(sphere((s * 1.27, 1.7, -0.22), 0.16), k=0.05)
    # fluffy canopy: two tones
    rng = _rng(7)
    c1 = m.group(rgb(64, 132, 52), min_tris=1200)
    c2 = m.group(rgb(110, 180, 72), min_tris=1000)
    c1.add(ell((0, 3.0, 0.1), (1.25, 0.75, 1.15)))
    for i in range(9):
        a = i / 9 * 2 * math.pi
        c1.add(sphere((math.sin(a) * 1.05, 2.75 + 0.1 * math.sin(3 * a), math.cos(a) * 1.0 + 0.1), 0.5), k=0.3)
    for i in range(7):
        a = i / 7 * 2 * math.pi + 0.4
        c2.add(sphere((math.sin(a) * 0.7, 3.45 + 0.08 * math.cos(2 * a), math.cos(a) * 0.65 + 0.1), 0.42 + 0.04 * (i % 2)), k=0.25)
    c2.add(sphere((0, 3.75, 0.1), 0.5), k=0.25)
    # acorns hanging in the canopy
    acorn, capc = rgb(200, 140, 70), rgb(100, 70, 40)
    for i in range(6):
        a = i / 6 * 2 * math.pi + 0.3
        p = np.array([math.sin(a) * 1.25, 2.6 + 0.25 * (i % 2), math.cos(a) * 1.15 + 0.1])
        m.ball(acorn, p, [0.11, 0.14, 0.11], subdiv=1)
        m.ball(capc, p + [0, 0.1, 0], [0.12, 0.06, 0.12], subdiv=1)
    _ = rng
    return m


@boss("froggus")
def b_froggus():
    m = Model("boss_froggus", BUDGET_BOSS, radius=1.0)
    g = rgb(88, 168, 72)
    cream = rgb(240, 230, 170)
    b = m.group(g, min_tris=2200)
    b.add(ell((0, 0.95, 0.05), (1.1, 0.85, 1.0)))
    for s in (-1, 1):
        b.add(sphere((s * 0.42, 1.68, -0.32), 0.33), k=0.25)  # eye bumps
        b.add(ell((s * 0.9, 0.45, 0.45), (0.38, 0.32, 0.55)), k=0.2)  # haunches
        b.add(tube([(s * 0.6, 0.7, -0.6), (s * 0.7, 0.3, -0.85), (s * 0.72, 0.12, -0.95)], [0.18, 0.15, 0.13]), k=0.15)
    b.sub(ell((0, 1.0, -0.98), (0.75, 0.09, 0.25)), k=0.04)  # wide grin
    feet = m.group(lerp_c(g, rgb(255, 240, 150), 0.25), min_tris=250)
    for s in (-1, 1):
        for i, a in enumerate((-30, 0, 30)):
            d = np.array([math.sin(math.radians(a)), 0, -math.cos(math.radians(a))])
            p = np.array([s * 0.72, 0.1, -0.97])
            feet.add(capsule(p, p + d * 0.22 + [s * 0.03, 0, 0], 0.07))
        for i, a in enumerate((-50, -10, 30)):
            d = np.array([math.sin(math.radians(a)) * s, 0, -math.cos(math.radians(a))])
            p = np.array([s * 1.05, 0.12, 0.2])
            feet.add(capsule(p, p + d * 0.3, 0.08), k=0.03)
    belly = m.group(cream, min_tris=500)
    belly.add(ell((0, 0.72, -0.35), (0.8, 0.6, 0.72)))
    mouth = m.group(rgb(80, 30, 40), min_tris=150)
    mouth.add(ell((0, 1.0, -0.88), (0.72, 0.07, 0.2)))
    tongue = m.group(rgb(240, 110, 130), min_tris=120)
    tongue.add(ell((0.18, 0.92, -1.0), (0.18, 0.06, 0.16), rot(10, 0, 8)))
    spots = m.group(lerp_c(g, rgb(24, 40, 20), 0.35), min_tris=200)
    for p, r in (((0.5, 1.5, 0.5), 0.16), ((-0.35, 1.62, 0.35), 0.13), ((0.0, 1.55, 0.75), 0.11), ((-0.75, 1.15, 0.5), 0.13), ((0.82, 1.05, 0.15), 0.1)):
        spots.add(sphere(p, r))
    spots.inter(ell((0, 0.95, 0.05), (1.13, 0.88, 1.03)))
    big_eyes(m, 0.42, 1.74, -0.52, 0.24, rgb(255, 200, 40), yaw=18)
    # tiny gold crown between the eyes
    cr = m.group(GOLD, min_tris=200)
    cr.add(cyl((0, 1.95, -0.1), 0.14, 0.2, round_=0.03))
    cr.sub(cyl((0, 1.99, -0.1), 0.16, 0.15, round_=0.02))
    for i in range(5):
        a = i / 5 * 2 * math.pi
        cr.add(cone((math.sin(a) * 0.18, 2.0, -0.1 + math.cos(a) * 0.18), (math.sin(a) * 0.19, 2.17, -0.1 + math.cos(a) * 0.19), 0.05, 0.02), k=0.02)
    m.ball(rgb(230, 50, 70), (0, 1.95, -0.31), 0.05, subdiv=1)
    # lily pad with a notch
    pad = m.group(rgb(70, 150, 70), min_tris=300)
    pad.add(cyl((0, 0.04, 0.05), 0.08, 1.45, round_=0.035))
    pad.sub(cone((0, 0.04, 0.05), (0, 0.04, 1.6), 0.02, 0.45), k=0.02)
    veins = m.group(rgb(110, 185, 90), min_tris=120)
    for i in range(7):
        a = math.radians(-150 + i * 50)
        veins.add(capsule((0, 0.085, 0.05), (math.sin(a) * 1.25, 0.085, 0.05 + math.cos(a) * 1.25), 0.025))
    veins.inter(cyl((0, 0.04, 0.05), 0.2, 1.38))
    return m


@boss("serpent_sisters")
def b_serpent_sisters():
    m = Model("boss_serpent_sisters", BUDGET_BOSS, radius=1.0)
    teal = rgb(64, 140, 120)
    belly = rgb(230, 200, 120)
    gold = rgb(240, 196, 70)
    body = m.group(teal, min_tris=2600)
    # coils: a spiral tube winding up
    pts, rad = [], []
    for i in range(40):
        u = i / 39
        a = u * 2.6 * 2 * math.pi
        r = 1.0 - 0.45 * u
        pts.append((math.sin(a) * r, 0.22 + u * 0.75, math.cos(a) * r))
        rad.append(0.26 - 0.06 * u)
    # rise into the neck (main sister) toward the front
    last = np.array(pts[-1])
    neck = [last, (0, 1.25, 0.05), (0, 1.75, -0.1), (0, 2.15, -0.2)]
    body.add(tube(pts + neck[1:], rad + [0.19, 0.17, 0.16]))
    # main head + hood
    head = np.array([0, 2.3, -0.38])
    body.add(ell(head, (0.27, 0.2, 0.36)), k=0.12)
    body.add(ell((0, 1.95, -0.08), (0.62, 0.55, 0.12), rot(-12, 0, 0)), k=0.12)
    # two smaller sisters rising from the coils
    sis = []
    for s in (-1, 1):
        base = np.array([s * 0.75, 0.5, -0.3])
        top = np.array([s * 0.95, 1.45, -0.55])
        body.add(tube([base, base + [s * 0.15, 0.45, 0.05], top], [0.15, 0.13, 0.12]), k=0.1)
        h = top + [s * 0.02, 0.1, -0.2]
        body.add(ell(h, (0.18, 0.14, 0.25)), k=0.08)
        body.add(ell(top + [0, -0.12, 0.08], (0.36, 0.32, 0.08), rot(-12, s * 10, 0)), k=0.08)
        sis.append((h, top))
    # cream belly scales on the hood fronts / necks
    bel = m.group(belly, min_tris=400)
    bel.add(ell((0, 1.85, -0.21), (0.32, 0.42, 0.06), rot(-12, 0, 0)))
    for h, top in sis:
        bel.add(ell(top + [0, -0.18, -0.02], (0.19, 0.24, 0.05), rot(-12, 0, 0)))
    # golden hood pattern: spectacle marks on the back of the hoods
    pat = m.group(gold, min_tris=200)
    pat.add(sym(torus((0.22, 2.05, 0.06), 0.11, 0.035, rot(78, 0, 0))))
    pat.add(capsule((-0.22, 1.92, 0.07), (0.22, 1.92, 0.07), 0.035))
    # bands of gold along the coils
    band = m.group(gold, min_tris=400)
    for i in range(4, 40, 6):
        p = np.array(pts[i])
        band.add(sphere(p + [0, rad[i] * 0.75, 0], rad[i] * 0.42))
    band.inter(tube(pts, [r + 0.02 for r in rad]))
    # eyes, fangs, tongue
    big_eyes(m, 0.14, 2.38, -0.6, 0.085, rgb(255, 220, 60), yaw=25, pupil=rgb(20, 20, 20))
    for h, _ in sis:
        for s in (-1, 1):
            c = h + [s * 0.09, 0.07, -0.18]
            m.ball(rgb(255, 220, 60), c, [0.055, 0.06, 0.04], subdiv=1)
            m.ball(EYE, c + [0, 0, -0.03], [0.02, 0.045, 0.02], subdiv=0)
    fang = m.group(WHITE, min_tris=60)
    fang.add(sym(cone((0.07, 2.22, -0.66), (0.07, 2.08, -0.68), 0.03, 0.006)))
    tg = m.group(rgb(230, 60, 80), min_tris=80)
    tg.add(tube([(0, 2.22, -0.7), (0, 2.18, -0.86), (0.05, 2.16, -0.96)], [0.025, 0.02, 0.012]))
    tg.add(tube([(0, 2.18, -0.86), (-0.05, 2.16, -0.96)], [0.02, 0.012]))
    # three glowing charm beads on the coils
    for i in (8, 20, 31):
        p = np.array(pts[i])
        out = p * [1, 0, 1]
        out = out / max(np.linalg.norm(out), 1e-6)
        m.ball(rgb(120, 255, 200), p + out * rad[i] * 0.95 + [0, 0.05, 0], 0.11, subdiv=2)
    return m


@boss("my_grandma")
def b_my_grandma():
    m = Model("boss_my_grandma", BUDGET_BOSS, radius=1.0)
    lilac = rgb(196, 150, 200)
    lilac_dk = rgb(150, 110, 170)
    skin = rgb(250, 215, 190)
    hair = rgb(232, 232, 238)
    apron_c = rgb(255, 248, 236)
    body = m.group(lilac, min_tris=1500)
    body.add(ell((0, 0.75, 0), (0.92, 1.05, 0.85)))  # bell skirt + cardigan
    body.add(ell((0, 1.6, 0.0), (0.62, 0.45, 0.5)), k=0.3)  # shoulders
    # right arm raised (slipper), left arm forward (yarn)
    body.add(tube([(0.55, 1.75, 0), (0.88, 2.2, 0.05), (0.95, 2.7, 0.0)], [0.2, 0.17, 0.15]), k=0.12)
    body.add(tube([(-0.55, 1.7, 0), (-0.9, 1.45, -0.2), (-1.0, 1.35, -0.45)], [0.2, 0.17, 0.15]), k=0.12)
    body.inter(plane((0, -1, 0), -0.2), k=0.03)
    trim = m.group(lilac_dk, min_tris=300)
    trim.add(torus((0, 0.24, 0), 0.8, 0.07))
    for i in range(4):
        m.ball(rgb(240, 220, 120), (0, 1.3 + i * 0.13, -0.6 + i * 0.01), [0.045, 0.045, 0.03], subdiv=1)
    cuff = m.group(lilac_dk, min_tris=120)
    cuff.add(torus((0.95, 2.72, 0), 0.14, 0.05))
    cuff.add(torus((-1.0, 1.36, -0.47), 0.14, 0.05, rot(70, 0, 0)))
    apron = m.group(apron_c, min_tris=400)
    apron.add(ell((0, 0.85, -0.55), (0.55, 0.62, 0.35)))
    apron.add(ell((0, 1.45, -0.42), (0.3, 0.2, 0.15)), k=0.05)
    apron.inter(plane((0, -1, 0), -0.24))
    pk = m.group(rgb(240, 150, 170), min_tris=60)
    pk.add(rbox((0.2, 0.7, -0.86), (0.13, 0.11, 0.04), r=0.025, R=rot(-10, 0, 0)))
    # feet
    shoes = m.group(rgb(110, 70, 60), min_tris=120)
    shoes.add(sym(ell((0.3, 0.12, -0.72), (0.17, 0.11, 0.24))))
    # head
    hd = m.group(skin, min_tris=900)
    head = np.array([0, 2.2, -0.08])
    hd.add(sphere(head, 0.48))
    hd.add(sym(sphere(head + [0.47, -0.05, 0.02], 0.08)), k=0.04)  # ears
    hd.add(ell(head + [0, -0.06, -0.47], (0.09, 0.08, 0.08)), k=0.05)  # nose
    hd.add(sphere((0.95, 2.95, 0), 0.14))  # hands
    hd.add(sphere((-1.02, 1.36, -0.55), 0.14))
    hr = m.group(hair, min_tris=700)
    hr.add(ell(head + [0, 0.12, 0.08], (0.52, 0.45, 0.5)))
    hr.sub(ell(head + [0, -0.1, -0.35], (0.5, 0.42, 0.4)), k=0.08)
    hr.add(sphere(head + [0, 0.53, 0.12], 0.26), k=0.08)  # bun
    hr.add(sym(sphere(head + [0.4, 0.08, -0.12], 0.14)), k=0.08)  # curls
    m.ball(rgb(255, 120, 150), head + [0.15, 0.68, 0.18], [0.06, 0.06, 0.14], rot(0, 0, 30), subdiv=1)  # pin
    blush = rgb(250, 160, 170)
    m.sym_ball(blush, head + [0.27, -0.12, -0.36], [0.1, 0.06, 0.04], rot(0, -35, 0), subdiv=1)
    # round gold glasses + kind eyes
    gl = m.group(rgb(220, 175, 60), min_tris=300)
    for s in (-1, 1):
        gl.add(torus(head + [s * 0.17, 0.04, -0.47], 0.12, 0.022, rot(90, 0, 0)))
    gl.add(capsule(head + [-0.05, 0.05, -0.48], head + [0.05, 0.05, -0.48], 0.018))
    gl.add(sym(capsule(head + [0.29, 0.05, -0.45], head + [0.45, 0.06, -0.1], 0.016)))
    m.sym_ball(EYE, head + [0.17, 0.04, -0.44], [0.045, 0.055, 0.03], subdiv=1)
    m.sym_ball(WHITE, head + [0.15, 0.07, -0.47], 0.015, subdiv=0)
    smile = m.group(rgb(180, 80, 90), min_tris=60)
    smile.add(tube([head + [-0.12, -0.2, -0.42], head + [0, -0.25, -0.44], head + [0.12, -0.2, -0.42]], 0.022))
    # the huge pink fluffy slipper overhead
    sl = m.group(rgb(240, 110, 150), min_tris=500)
    sp = np.array([0.95, 3.25, -0.05])
    sl.add(ell(sp, (0.3, 0.62, 0.15), rot(0, 0, -15)))
    sole = m.group(rgb(120, 70, 60), min_tris=200)
    sole.add(ell(sp + [0.0, 0.0, 0.1], (0.31, 0.63, 0.06), rot(0, 0, -15)))
    fluff = m.group(WHITE, min_tris=400)
    fl = sp + [-0.08, 0.3, -0.12]
    for i in range(7):
        a = i / 7 * 2 * math.pi
        fluff.add(sphere(fl + [math.cos(a) * 0.17, math.sin(a) * 0.17, -0.04], 0.12), k=0.06)
    fluff.add(sphere(fl + [0, 0, -0.08], 0.14), k=0.06)
    # red yarn ball with wraps
    yb = np.array([-1.05, 1.32, -0.82])
    y1 = m.group(rgb(230, 80, 90), min_tris=400)
    y1.add(sphere(yb, 0.3))
    y2 = m.group(rgb(255, 150, 150), min_tris=300)
    for i, (rx, rz) in enumerate(((20, 0), (70, 30), (-40, 70), (90, -60))):
        y2.add(torus(yb, 0.29, 0.025, rot(rx, 0, rz)))
    y2.add(tube([yb + [0.1, -0.25, -0.12], yb + [0.25, -0.6, -0.2], yb + [0.1, -1.0, -0.1], yb + [0.3, -1.25, 0]], 0.025), k=0.02)
    # rug
    return m


@boss("floating_witch")
def b_floating_witch():
    m = Model("boss_floating_witch", BUDGET_BOSS, radius=1.0)
    robe = rgb(120, 70, 170)
    skin = rgb(150, 210, 130)
    black = rgb(40, 30, 50)
    by = 0.75  # broom height (she floats)
    # broom
    w = m.group(rgb(130, 90, 50), min_tris=200)
    w.add(capsule((0, by, -1.15), (0, by, 0.95), 0.06))
    st = m.group(rgb(220, 180, 90), min_tris=300)
    st.add(cone((0, by, 0.85), (0, by + 0.02, 1.6), 0.14, 0.32))
    tie = m.group(rgb(150, 60, 60), min_tris=80)
    tie.add(torus((0, by, 0.95), 0.13, 0.04, rot(90, 0, 0)))
    # body seated on the broom
    r = m.group(robe, min_tris=1500)
    r.add(cone((0, by + 0.05, 0.05), (0, by + 1.4, 0), 0.6, 0.32))
    r.add(sym(tube([(0.25, by + 0.15, -0.05), (0.32, by + 0.0, -0.45), (0.3, by - 0.45, -0.55)], [0.2, 0.16, 0.14])), k=0.15)  # knees, legs
    r.add(sym(tube([(0.33, by + 1.25, 0), (0.62, by + 0.95, -0.3), (0.32, by + 0.62, -0.62)], [0.14, 0.13, 0.12])), k=0.12)  # arms to the broom
    r.sub(plane((0, -1, 0), -(by - 0.02)), k=0.02)  # flat-ish base under the robe
    boots = m.group(black, min_tris=150)
    boots.add(sym(tube([(0.3, by - 0.5, -0.55), (0.3, by - 0.62, -0.75), (0.25, by - 0.5, -0.92)], [0.1, 0.09, 0.05])))
    hands = m.group(skin, min_tris=400)
    hands.add(sym(sphere((0.12, by + 0.08, -0.65), 0.11)))
    head = np.array([0, by + 1.72, 0])
    hands.add(sphere(head, 0.42))
    hands.add(tube([head + [0, -0.02, -0.38], head + [0, -0.06, -0.58], head + [0, -0.16, -0.66]], [0.08, 0.06, 0.03]), k=0.05)  # long nose
    hands.add(sym(cone(head + [0.38, 0.0, 0.0], head + [0.55, 0.12, 0.05], 0.07, 0.02)), k=0.04)  # pointy ears
    m.ball(rgb(120, 90, 50), head + [0.06, -0.14, -0.58], 0.03, subdiv=0)  # wart
    big_eyes(m, 0.15, head[1] + 0.08, -0.34, 0.11, rgb(255, 230, 80), yaw=16)
    hairc = m.group(rgb(70, 40, 90), min_tris=300)
    hairc.add(ell(head + [0, 0.0, 0.18], (0.47, 0.45, 0.38)))
    hairc.add(tube([head + [0, 0.0, 0.3], head + [0, -0.5, 0.42], head + [0, -0.85, 0.35]], [0.3, 0.22, 0.1]), k=0.12)
    hairc.sub(ell(head + [0, -0.05, -0.2], (0.44, 0.5, 0.38)), k=0.05)
    smile = m.group(rgb(70, 30, 50), min_tris=50)
    smile.add(tube([head + [-0.13, -0.2, -0.36], head + [0, -0.25, -0.38], head + [0.15, -0.17, -0.36]], 0.022))
    # hat: wide brim + bent cone + gold band
    hat = m.group(black, min_tris=600)
    hb = head + [0, 0.3, 0]
    hat.add(cyl(hb, 0.05, 0.72, round_=0.02))
    hat.add(tube([hb, hb + [0, 0.55, 0.05], hb + [0, 0.95, 0.2], hb + [0, 1.15, 0.45]], [0.4, 0.24, 0.1, 0.03]), k=0.05)
    band = m.group(rgb(255, 200, 60), min_tris=150)
    band.add(cone(hb + [0, 0.04, 0], hb + [0, 0.17, 0.01], 0.405, 0.37))
    band.sub(cone(hb + [0, 0.0, 0], hb + [0, 0.2, 0.01], 0.37, 0.33))
    m.ball(rgb(255, 230, 120), hb + [0, 0.1, -0.39], [0.08, 0.08, 0.03], subdiv=1)  # buckle
    # roulette spell wheel behind her (faces -Z)
    wc = np.array([0, by + 1.45, 0.85])
    Rw = rot(90, 0, 0)
    cols = [rgb(255, 80, 80), rgb(255, 200, 60), rgb(90, 200, 255), rgb(140, 230, 110)]
    for ci, col in enumerate(cols):
        g = m.group(col, min_tris=150)
        for k in (ci, ci + 4):
            a0 = k * math.pi / 4
            a1 = a0 + math.pi / 4
            g.add(cyl(wc, 0.08, 1.1, Rw, round_=0.02))
            # wedge between angles a0 and a1 in the XY plane
            n0 = np.array([math.sin(a0), -math.cos(a0), 0])
            n1 = np.array([-math.sin(a1), math.cos(a1), 0])
            g.ops[-1] = ("add", _wedge(wc, Rw, n0, n1), 0.0)
    rim = m.group(rgb(255, 210, 80), min_tris=400)
    rim.add(torus(wc, 1.1, 0.07, Rw))
    for k in range(8):
        a = k * math.pi / 4
        rim.add(capsule(wc + [0, 0, -0.05], wc + [math.cos(a) * 1.08, math.sin(a) * 1.08, -0.05], 0.025), k=0.01)
        m.ball(WHITE, wc + [math.cos(a + 0.39) * 1.17, math.sin(a + 0.39) * 1.17, -0.03], 0.05, subdiv=1)
    rim.add(cyl(wc + [0, 0, -0.06], 0.1, 0.17, Rw, round_=0.03))
    return m


def _wedge(c, R, n0, n1):
    """A disc sector: cylinder ∩ two half-spaces (normals n0, n1 through c)."""
    from meshkit import Shape

    disc = cyl(c, 0.08, 1.1, R, round_=0.02)
    c = np.asarray(c, dtype=float)

    def f(p):
        d = disc(p)
        d = np.maximum(d, (p - c) @ n0)
        d = np.maximum(d, (p - c) @ n1)
        return d

    return Shape(f, disc.lo, disc.hi)


@boss("corndog_bunny")
def b_corndog_bunny():
    m = Model("boss_corndog_bunny", BUDGET_BOSS, radius=1.0)
    fur = rgb(245, 235, 220)
    b = m.group(fur, min_tris=2400)
    b.add(ell((0, 1.0, 0.05), (0.72, 0.82, 0.62)))
    head = np.array([0, 2.05, -0.2])
    b.add(sphere(head, 0.55), k=0.25)
    b.add(sym(ell(head + [0.28, -0.18, -0.32], (0.2, 0.16, 0.18))), k=0.1)  # cheeks
    b.add(sym(ell((0.4, 0.22, -0.3), (0.24, 0.2, 0.45))), k=0.12)  # big feet
    b.add(sym(ell((0.55, 0.55, 0.2), (0.25, 0.4, 0.4))), k=0.15)  # haunches
    b.add(tube([(0.55, 1.45, 0), (0.85, 1.75, -0.15), (0.75, 2.1, -0.35)], [0.17, 0.14, 0.13]), k=0.12)  # right arm up
    b.add(tube([(-0.55, 1.45, 0), (-0.75, 1.15, -0.3), (-0.6, 1.05, -0.5)], [0.17, 0.14, 0.13]), k=0.12)
    b.add(sphere((0, 0.8, 0.72), 0.22), k=0.05)  # cotton tail
    # tall ears with pink lining
    ears = m.group(fur, min_tris=600)
    inner = m.group(rgb(255, 170, 185), min_tris=300)
    for s in (-1, 1):
        base = head + [s * 0.22, 0.4, 0.05]
        R = rot(-8, 0, -s * 12)
        tip = base + R @ np.array([0, 1.1, 0])
        ears.add(cone(base, tip, 0.16, 0.12))
        ears.add(ell((base + tip) / 2, (0.19, 0.5, 0.1), R), k=0.08)
        inner.add(ell((base + tip) / 2 + [0, 0.05, -0.08], (0.11, 0.42, 0.04), R))
    belly = m.group(rgb(255, 250, 240), min_tris=300)
    belly.add(ell((0, 1.0, -0.38), (0.5, 0.58, 0.3)))
    pads = m.group(rgb(255, 170, 185), min_tris=100)
    pads.add(sym(ell((0.4, 0.17, -0.72), (0.13, 0.08, 0.06))))
    big_eyes(m, 0.22, head[1] + 0.08, head[2] - 0.47, 0.14, rgb(220, 40, 40), yaw=16)
    m.ball(rgb(255, 130, 150), head + [0, -0.1, -0.56], [0.08, 0.06, 0.05], subdiv=1)
    teeth = m.group(WHITE, min_tris=60)
    teeth.add(rbox(head + [0, -0.3, -0.5], (0.08, 0.08, 0.03), r=0.02))
    brow = m.group(rgb(200, 180, 170), min_tris=60)
    brow.add(sym(capsule(head + [0.08, 0.27, -0.5], head + [0.34, 0.33, -0.42], 0.03)))
    # the giant corndog club over the shoulder
    hand = np.array([0.72, 2.15, -0.38])
    m.group(fur, min_tris=80).add(sphere(hand, 0.14))
    d = np.array([-0.35, 1.0, 0.35])
    d = d / np.linalg.norm(d)
    stick = m.group(rgb(210, 180, 130), min_tris=150)
    stick.add(capsule(hand - d * 0.35, hand + d * 0.7, 0.045))
    dog = m.group(rgb(214, 150, 70), min_tris=500)
    c0, c1 = hand + d * 0.7, hand + d * 1.95
    dog.add(capsule(c0, c1, 0.25))
    # mustard + ketchup zigzags along the dog
    perp = np.cross(d, [0, 0, 1.0])
    perp = perp / np.linalg.norm(perp)
    up = np.cross(perp, d)
    for col, ph in ((rgb(250, 210, 40), 0.0), (rgb(220, 50, 40), 0.5)):
        z = m.group(col, min_tris=150)
        pts = []
        for i in range(9):
            u = 0.08 + i / 8 * 0.84
            side = 1 if (i % 2) else -1
            ang = side * 0.7 + ph
            pts.append(c0 + (c1 - c0) * u + (np.cos(ang) * -up + np.sin(ang) * perp) * 0.245 + d * ph * 0.06)
        z.add(tube(pts, 0.04))
    return m


@boss("spider_machine")
def b_spider_machine():
    m = Model("boss_spider_machine", BUDGET_BOSS, radius=1.0)
    steel = rgb(120, 124, 136)
    dark = rgb(60, 60, 66)
    b = m.group(steel, min_tris=1500)
    b.add(ell((0, 1.6, 0.3), (0.95, 0.6, 1.05)))
    b.add(ell((0, 1.55, -0.75), (0.62, 0.45, 0.45)), k=0.2)  # head section
    b.sub(sphere((0, 1.55, -1.25), 0.3), k=0.04)  # eye socket
    plates = m.group(lerp_c(steel, WHITE, 0.25), min_tris=400)
    for i in range(3):
        plates.add(torus((0, 1.6 + 0.0, 0.3), 0.92 - i * 0.0, 0.045, rot(90 - 40 + i * 40, 0, 0)))
    plates.inter(ell((0, 1.6, 0.3), (1.0, 0.65, 1.1)))
    rivet = rgb(255, 200, 60)
    for i in range(8):
        a = i / 8 * 2 * math.pi
        m.ball(rivet, (math.sin(a) * 0.9, 1.62, 0.3 + math.cos(a) * 1.0), 0.05, subdiv=0)
    # big red laser eye
    m.ball(rgb(255, 50, 40), (0, 1.55, -1.08), 0.26, subdiv=2)
    m.ball(rgb(255, 200, 190), (-0.07, 1.63, -1.3), 0.07, subdiv=1)
    ring = m.group(dark, min_tris=200)
    ring.add(torus((0, 1.55, -1.12), 0.27, 0.05, rot(90, 0, 0)))
    m.sym_ball(rgb(255, 120, 60), (0.32, 1.78, -1.0), 0.08, subdiv=1)
    # cockpit: glass shell, open at the back, with the mouse pilot
    glass = m.group(rgb(150, 220, 255), min_tris=500)
    dome = np.array([0, 2.05, 0.35])
    glass.add(sphere(dome, 0.5))
    glass.sub(sphere(dome, 0.45))
    glass.sub(plane((0, 0, -1), -0.05 - dome[2] + 0.0), k=0.0)  # keep the front half only
    glass.sub(plane((0, -1, 0), -(dome[1] - 0.05)))
    rim = m.group(dark, min_tris=200)
    rim.add(torus(dome + [0, -0.05, 0], 0.5, 0.06))
    pilot = m.group(rgb(139, 107, 78), min_tris=400)
    ph = dome + [0, 0.15, 0.1]
    pilot.add(sphere(ph, 0.22))
    pilot.add(sym(ell(ph + [0.17, 0.2, 0.02], (0.13, 0.13, 0.04), rot(0, 0, -20))), k=0.04)
    m.sym_ball(PINK, ph + [0.18, 0.2, -0.01], [0.08, 0.08, 0.02], rot(0, 0, -20), subdiv=1)
    m.ball(PINK_DARK, ph + [0, -0.03, -0.23], 0.04, subdiv=0)
    m.sym_ball(EYE, ph + [0.08, 0.05, -0.19], [0.035, 0.045, 0.02], subdiv=0)
    # antenna
    ant = m.group(dark, min_tris=60)
    ant.add(capsule((0.45, 2.0, 0.9), (0.45, 2.55, 0.95), 0.025))
    m.ball(rgb(255, 60, 60), (0.45, 2.58, 0.95), 0.07, subdiv=1)
    # eight segmented legs
    legs = m.group(steel, min_tris=1800)
    joints = m.group(rivet, min_tris=400)
    feet = m.group(dark, min_tris=500)
    for s in (-1, 1):
        for i, zz in enumerate((-0.6, -0.1, 0.4, 0.9)):
            hip = np.array([s * 0.75, 1.55, zz])
            spread = (zz - 0.15) * 0.9
            outd = np.array([s * 1.0, 0, spread])
            outd = outd / np.linalg.norm(outd)
            knee = hip + outd * 0.75 + [0, 0.75, 0]
            foot = hip + outd * 1.6 + [0, -1.5, 0]
            foot[1] = 0.08
            legs.add(cone(hip, knee, 0.14, 0.1))
            legs.add(cone(knee, foot + [0, 0.2, 0], 0.1, 0.06))
            joints.add(sphere(knee, 0.14))
            joints.add(sphere(hip, 0.15))
            feet.add(cone(foot + [0, 0.25, 0], foot, 0.09, 0.03))
    return m


@boss("green_gorilla")
def b_green_gorilla():
    m = Model("boss_green_gorilla", BUDGET_BOSS, radius=1.0)
    g = rgb(60, 150, 70)
    skin = rgb(70, 90, 70)
    face_c = rgb(120, 150, 110)
    b = m.group(g, min_tris=2600)
    b.add(ell((0, 1.45, 0.15), (0.85, 0.85, 0.7), rot(-15, 0, 0)))  # torso
    b.add(ell((0, 0.75, 0.3), (0.55, 0.45, 0.45)), k=0.25)  # hips
    head = np.array([0, 2.15, -0.3])
    b.add(sphere(head, 0.42), k=0.25)
    b.add(ell(head + [0, 0.15, 0.05], (0.38, 0.32, 0.35)), k=0.1)  # crest
    for s in (-1, 1):
        sh = np.array([s * 0.8, 1.85, -0.05])
        b.add(sphere(sh, 0.42), k=0.2)  # huge shoulders
        b.add(tube([sh, sh + [s * 0.35, -0.55, -0.15], sh + [s * 0.35, -1.25, -0.35]], [0.36, 0.3, 0.3]), k=0.12)
        b.add(sym(ell((0.35, 0.35, 0.35), (0.2, 0.33, 0.22))), k=0.1)  # legs
    fists = m.group(skin, min_tris=600)
    for s in (-1, 1):
        f = np.array([s * 1.15, 0.38, -0.42])
        fists.add(ell(f, (0.38, 0.34, 0.38)))
        for k in range(4):
            fists.add(sphere(f + [s * 0.0 + (k - 1.5) * 0.15, 0.05, -0.33], 0.1), k=0.05)
    fists.add(sym(ell((0.35, 0.08, -0.12), (0.2, 0.08, 0.26))))  # feet
    chest = m.group(lerp_c(g, skin, 0.6), min_tris=300)
    chest.add(sym(ell((0.28, 1.6, -0.43), (0.3, 0.24, 0.2), rot(-15, 0, 0))))
    face = m.group(face_c, min_tris=500)
    face.add(ell(head + [0, -0.08, -0.3], (0.33, 0.3, 0.2)))
    face.add(ell(head + [0, -0.22, -0.36], (0.24, 0.15, 0.15)), k=0.05)  # muzzle
    brow = m.group(skin, min_tris=200)
    brow.add(capsule(head + [-0.26, 0.15, -0.35], head + [0.26, 0.15, -0.35], 0.08))
    brow.add(sym(sphere(head + [0.08, -0.17, -0.5], 0.035)))  # nostrils (dark)
    big_eyes(m, 0.13, head[1] + 0.02, head[2] - 0.43, 0.08, rgb(255, 210, 60), yaw=12)
    mouth = m.group(rgb(40, 50, 40), min_tris=50)
    mouth.add(tube([head + [-0.12, -0.3, -0.48], head + [0, -0.33, -0.5], head + [0.12, -0.3, -0.48]], 0.022))
    # banana crown and banana bandolier
    yel = rgb(255, 225, 70)
    ban = m.group(yel, min_tris=900)
    tipc = m.group(rgb(110, 80, 40), min_tris=200)
    for i in range(7):
        a = i / 7 * 2 * math.pi
        dirv = np.array([math.sin(a), 0, math.cos(a)])
        base = head + [0, 0.3, 0.05] + dirv * 0.22
        mid = base + dirv * 0.08 + [0, 0.18, 0]
        top = base + dirv * 0.02 + [0, 0.34, 0]
        ban.add(tube([base, mid, top], [0.06, 0.07, 0.04]))
        tipc.add(sphere(top + [0, 0.02, 0], 0.035))
    # strap across the chest (left shoulder to right hip)
    strap = m.group(rgb(120, 80, 40), min_tris=300)
    s0, s1 = np.array([-0.75, 2.05, -0.05]), np.array([0.7, 0.85, -0.35])
    sm = np.array([0, 1.5, -0.68])
    strap.add(tube([s0, (s0 + sm) / 2 + [0, 0, -0.12], sm, (sm + s1) / 2 + [0, 0, -0.08], s1], 0.07))
    for i in range(5):
        u = 0.15 + i * 0.17
        p = (1 - u) ** 2 * s0 + 2 * (1 - u) * u * (sm + [0, 0, -0.25]) + u * u * s1
        p = p + [0, 0, -0.12]
        ban.add(tube([p + [-0.05, 0.12, 0], p + [0.0, 0.0, -0.04], p + [-0.03, -0.14, 0]], [0.04, 0.055, 0.035]))
    return m


@boss("paper_dinosaur")
def b_paper_dinosaur():
    """Origami T-rex: smooth SDF forms decimated hard and flat shaded, so the
    surface breaks into crisp paper facets."""
    m = Model("boss_paper_dinosaur", BUDGET_BOSS, radius=1.0)
    paper = rgb(236, 232, 220)
    fold = rgb(206, 200, 186)
    red = rgb(230, 70, 70)
    b = m.group(paper, min_tris=500, flat=True, max_tris=900)
    b.add(ell((0, 1.45, 0.15), (0.5, 0.55, 0.8), rot(-18, 0, 0)))
    b.add(cone((0, 1.5, 0.6), (0, 0.9, 2.0), 0.36, 0.04), k=0.2)  # tail
    b.add(cone((0, 1.75, -0.35), (0, 2.2, -0.62), 0.3, 0.24), k=0.15)  # neck
    hd = np.array([0, 2.35, -0.85])
    b.add(ell(hd, (0.3, 0.27, 0.42)), k=0.1)
    b.add(ell(hd + [0, -0.05, -0.35], (0.24, 0.17, 0.3)), k=0.08)  # snout
    b.sub(ell(hd + [0, -0.17, -0.45], (0.4, 0.045, 0.32), rot(-8, 0, 0)), k=0.01)  # mouth slit
    b.add(sym(cone((0.32, 1.45, -0.45), (0.4, 1.25, -0.75), 0.09, 0.04)), k=0.05)  # tiny arms
    jaw = m.group(fold, min_tris=60, flat=True, max_tris=120)
    jaw.add(ell(hd + [0, -0.25, -0.3], (0.21, 0.07, 0.3), rot(10, 0, 0)))
    legs = m.group(fold, min_tris=300, flat=True, max_tris=520)
    for s in (-1, 1):
        hip = np.array([s * 0.42, 1.3, 0.3])
        knee = hip + [s * 0.06, -0.45, -0.3]
        ank = np.array([s * 0.48, 0.22, 0.3])
        legs.add(ell(hip, (0.26, 0.4, 0.35)), k=0.1)
        legs.add(cone(hip, knee, 0.28, 0.17), k=0.1)
        legs.add(cone(knee, ank, 0.17, 0.11), k=0.05)
        legs.add(ell((s * 0.48, 0.1, 0.1), (0.2, 0.1, 0.34)), k=0.05)
    claws = m.group(WHITE, min_tris=40, flat=True, max_tris=90)
    for s in (-1, 1):
        for k in (-1, 0, 1):
            claws.add(cone((s * 0.48 + k * 0.11, 0.07, -0.18), (s * 0.48 + k * 0.14, 0.04, -0.38), 0.05, 0.01))
    belly = m.group(fold, min_tris=60, flat=True, max_tris=140)
    belly.add(ell((0, 1.3, -0.3), (0.3, 0.42, 0.12), rot(-30, 0, 0)))
    sp = m.group(red, min_tris=200, flat=True, max_tris=360)
    spine = [(0, 2.62, -0.8), (0, 2.25, -0.45), (0, 2.02, -0.1), (0, 1.92, 0.3), (0, 1.62, 0.75), (0, 1.32, 1.2), (0, 1.07, 1.6)]
    for i, p in enumerate(spine):
        h = 0.3 - i * 0.025
        p = np.array(p)
        sp.add(cone(p - [0, 0.1, 0], p + [0, h, 0.1], 0.12 - i * 0.008, 0.01))
    teeth = m.group(WHITE, min_tris=40, flat=True, max_tris=80)
    for i in range(4):
        teeth.add(sym(cone((0.17, hd[1] - 0.15, hd[2] - 0.62 + i * 0.12), (0.17, hd[1] - 0.24, hd[2] - 0.62 + i * 0.12), 0.035, 0.005)))
    for s in (-1, 1):
        c = hd + [s * 0.26, 0.1, -0.15]
        m.ball(rgb(255, 60, 60), c, [0.05, 0.08, 0.08], subdiv=1)
        m.ball(EYE, c + [s * 0.035, 0, -0.01], [0.02, 0.05, 0.04], subdiv=0)
    return m


@boss("hematite_snake")
def b_hematite_snake():
    m = Model("boss_hematite_snake", BUDGET_BOSS, radius=1.0)
    iron = rgb(70, 60, 66)
    shine = rgb(120, 112, 124)
    red = rgb(220, 50, 40)
    segs = m.group(iron, min_tris=3000)
    seam = m.group(red, min_tris=1200)
    hi = m.group(shine, min_tris=500)
    # S-curve body lying on the ground, rising to the head at the front
    path = []
    n = 13
    for i in range(n):
        u = i / (n - 1)
        z = 1.5 - u * 2.2
        x = 0.7 * math.sin(u * 2.0 * math.pi) * (1 - u * 0.3)
        y = 0.25 if u < 0.7 else 0.25 + (u - 0.7) / 0.3 * 1.0
        path.append(np.array([x, y, z]))
    for i, p in enumerate(path):
        r = 0.18 + 0.12 * min(1.0, i / 4) - (0.04 if i > n - 3 else 0)
        nxt = path[min(i + 1, n - 1)] - path[max(i - 1, 0)]
        nxt = nxt / np.linalg.norm(nxt)
        # each plate: an ellipsoid elongated along the path
        yaw = math.degrees(math.atan2(nxt[0], nxt[2]))
        pitch = -math.degrees(math.asin(nxt[1]))
        R = rot(0, yaw, 0) @ rot(pitch, 0, 0)
        segs.add(ell(p, (r * 1.05, r * 0.9, r * 0.95), R))
        hi.add(ell(p + [0, r * 0.55, 0], (r * 0.55, r * 0.35, r * 0.5), R))
        if i < n - 1:
            q = (p + path[i + 1]) / 2
            seam.add(sphere(q, r * 0.8))
    hi.inter(union(*[ell(p, (0.4, 0.4, 0.4)) for p in path]))
    # head
    hd = path[-1] + [0, 0.15, -0.3]
    head = m.group(iron, min_tris=600)
    head.add(ell(hd, (0.32, 0.22, 0.42)))
    head.add(sym(ell(hd + [0.14, 0.12, -0.05], (0.12, 0.08, 0.2))), k=0.06)  # brow plates
    head.add(capsule(path[-1], hd, 0.2), k=0.1)
    m.sym_ball(rgb(255, 40, 40), hd + [0.18, 0.1, -0.22], [0.07, 0.05, 0.08], subdiv=1)
    m.sym_ball(rgb(255, 200, 190), hd + [0.19, 0.13, -0.28], 0.02, subdiv=0)
    jaw = m.group(red, min_tris=80)
    jaw.add(ell(hd + [0, -0.1, -0.25], (0.22, 0.03, 0.2)))
    fang = m.group(rgb(220, 220, 230), min_tris=60)
    fang.add(sym(cone(hd + [0.1, -0.08, -0.36], hd + [0.1, -0.24, -0.38], 0.035, 0.005)))
    # tail spike
    tail = m.group(red, min_tris=80)
    tail.add(cone(path[0] + [0, 0, 0.05], path[0] + [0, 0.05, 0.45], 0.12, 0.01))
    # red horseshoe magnet floating above
    mc = hd + [0, 0.95, 0.0]
    mag = m.group(red, min_tris=400)
    mag.add(torus(mc, 0.28, 0.1, rot(90, 0, 0)))
    mag.inter(plane((0, -1, 0), -mc[1]))
    mag.add(sym(capsule(mc + [0.28, 0.0, 0], mc + [0.28, -0.25, 0], 0.1)))
    tips = m.group(rgb(220, 220, 230), min_tris=120)
    tips.add(sym(cyl(mc + [0.28, -0.36, 0], 0.14, 0.105, round_=0.03)))
    return m


@boss("ice_dragon")
def b_ice_dragon():
    m = Model("boss_ice_dragon", BUDGET_BOSS, radius=1.0)
    ice = rgb(150, 210, 240)
    pale = rgb(230, 245, 255)
    crystal = rgb(200, 240, 255)
    wingc = rgb(170, 230, 255)
    b = m.group(ice, min_tris=2400)
    b.add(ell((0, 1.15, 0.25), (0.62, 0.55, 0.95)))
    b.add(tube([(0, 1.35, -0.4), (0, 1.75, -0.7), (0, 2.1, -0.75)], [0.32, 0.25, 0.22]), k=0.15)
    hd = np.array([0, 2.25, -0.95])
    b.add(ell(hd, (0.3, 0.26, 0.32)), k=0.1)
    b.add(ell(hd + [0, -0.06, -0.32], (0.2, 0.15, 0.25)), k=0.1)  # snout
    b.add(tube([(0, 1.1, 1.0), (0, 0.8, 1.5), (0.25, 0.55, 1.9), (0.5, 0.45, 2.05)], [0.3, 0.2, 0.12, 0.06]), k=0.15)
    for s in (-1, 1):
        for zz, front in ((-0.35, True), (0.75, False)):
            top = np.array([s * 0.42, 0.95, zz])
            b.add(tube([top, top + [s * 0.12, -0.45, -0.05], top + [s * 0.12, -0.85, -0.1]], [0.27 if not front else 0.22, 0.2, 0.18]), k=0.12)
    belly = m.group(pale, min_tris=500)
    belly.add(ell((0, 0.92, 0.1), (0.42, 0.33, 0.8)))
    belly.add(tube([(0, 1.35, -0.6), (0, 1.75, -0.88), (0, 2.05, -0.95)], [0.18, 0.15, 0.13]), k=0.05)
    feet = m.group(pale, min_tris=300)
    for s in (-1, 1):
        for zz in (-0.45, 0.65):
            for k in (-1, 0, 1):
                feet.add(cone((s * 0.54 + k * 0.1, 0.1, zz - 0.15), (s * 0.54 + k * 0.12, 0.05, zz - 0.35), 0.06, 0.015))
    cr = m.group(crystal, min_tris=900)
    cr.add(sym(cone(hd + [0.15, 0.15, 0.1], hd + [0.3, 0.55, 0.45], 0.08, 0.015)))  # horns
    cr.add(sym(cone(hd + [0.22, 0.0, 0.12], hd + [0.42, 0.12, 0.35], 0.05, 0.01)))
    spine = [(0, 2.45, -0.8), (0, 2.15, -0.55), (0, 1.75, -0.2), (0, 1.75, 0.2), (0, 1.65, 0.6), (0, 1.35, 1.05), (0, 1.0, 1.5), (0.25, 0.75, 1.9)]
    for i, p in enumerate(spine):
        p = np.array(p)
        cr.add(cone(p - [0, 0.12, 0], p + [0, 0.24 - i * 0.015, 0.1], 0.08, 0.01))
    cr.add(cone((0.5, 0.45, 2.05), (0.75, 0.42, 2.3), 0.09, 0.01))  # tail tip
    # crystal wings: bony fingers + translucent-looking membranes
    bones = m.group(crystal, min_tris=500)
    for s in (-1, 1):
        root = np.array([s * 0.45, 1.6, -0.05])
        elbow = root + [s * 0.6, 0.55, 0.15]
        bones.add(cone(root, elbow, 0.08, 0.06))
        tips = [elbow + [s * 0.85, 0.35, 0.05], elbow + [s * 0.95, -0.1, 0.45], elbow + [s * 0.7, -0.45, 0.8]]
        prev = root + [s * 0.1, -0.05, 0.6]
        for t in tips:
            bones.add(cone(elbow, t, 0.05, 0.015))
        pts = [root, elbow] + tips + [prev]
        for a, c in ((elbow, tips[0]), (tips[0], tips[1]), (tips[1], tips[2]), (tips[2], prev)):
            m.prism(wingc, root, a, c, 0.05)
            m.prism(lerp_c(wingc, WHITE, 0.35), root + (a - root) * 0.15 + (c - root) * 0.15, root + (a - root) * 0.8 + (c - root) * 0.12, root + (a - root) * 0.12 + (c - root) * 0.8, 0.07)
        _ = pts
    big_eyes(m, 0.17, hd[1] + 0.08, hd[2] - 0.22, 0.08, rgb(90, 200, 255), yaw=25)
    m.sym_ball(rgb(60, 90, 120), hd + [0.07, -0.02, -0.56], 0.025, subdiv=0)  # nostrils
    m.ball(rgb(200, 245, 255), hd + [0, -0.12, -0.62], [0.16, 0.1, 0.12], subdiv=2)  # frosty breath
    return m


@boss("void_cat")
def b_void_cat():
    m = Model("boss_void_cat", BUDGET_BOSS, radius=1.0)
    void = rgb(40, 24, 64)
    neb = rgb(90, 50, 150)
    b = m.group(void, min_tris=2400)
    b.add(ell((0, 0.95, 0.15), (0.7, 0.9, 0.62)))
    b.add(sym(ell((0.45, 0.4, 0.25), (0.3, 0.4, 0.45))), k=0.2)  # haunches
    b.add(sym(tube([(0.25, 1.1, -0.3), (0.28, 0.55, -0.45), (0.27, 0.12, -0.52)], [0.16, 0.14, 0.13])), k=0.12)  # front legs
    head = np.array([0, 2.0, -0.15])
    b.add(ell(head, (0.6, 0.5, 0.5)), k=0.22)
    b.add(sym(cone(head + [0.3, 0.3, 0.05], head + [0.45, 0.78, 0.05], 0.2, 0.03)), k=0.08)  # ears
    b.add(sym(ell(head + [0.25, -0.17, -0.3], (0.2, 0.15, 0.16))), k=0.08)
    # curled tail
    tp = [(0, 0.3, 0.7), (0.4, 0.2, 0.95), (0.85, 0.3, 0.8), (1.0, 0.6, 0.45), (0.95, 1.0, 0.3), (0.8, 1.25, 0.45)]
    b.add(tube(tp, [0.13, 0.13, 0.12, 0.11, 0.1, 0.09]), k=0.1)
    inner = m.group(rgb(140, 70, 200), min_tris=150)
    inner.add(sym(cone(head + [0.31, 0.32, -0.02], head + [0.44, 0.7, -0.02], 0.12, 0.02)))
    paws = m.group(rgb(70, 50, 100), min_tris=150)
    paws.add(sym(ell((0.27, 0.08, -0.6), (0.15, 0.08, 0.17))))
    # galaxy swirls embedded in the fur
    gx = m.group(neb, min_tris=700)
    for i in range(16):
        a = i / 16 * 4 * math.pi
        rr = 0.12 + i * 0.022
        gx.add(sphere((math.cos(a) * rr * 1.2, 1.0 + math.sin(a) * rr, -0.55), 0.07 + i * 0.004), k=0.08)
    gx.add(sphere((0.55, 1.2, 0.35), 0.18), k=0.1)
    gx.add(sphere((-0.5, 0.7, 0.45), 0.2), k=0.1)
    gx.inter(ell((0, 0.95, 0.15), (0.72, 0.92, 0.64)))
    # stars: deterministic points on the body surface
    rng = _rng(11)
    for i in range(26):
        u, v = rng.uniform(0, 2 * math.pi), rng.uniform(-0.9, 0.9)
        d = np.array([math.cos(u) * math.sqrt(1 - v * v), v, math.sin(u) * math.sqrt(1 - v * v)])
        p = np.array([0, 0.95, 0.15]) + d * [0.7, 0.9, 0.62]
        col = rgb(255, 250, 220) if i % 3 else rgb(200, 160, 255)
        m.ball(col, p, 0.028 + 0.012 * (i % 3), subdiv=0)
    for i in range(8):
        u, v = rng.uniform(-2.2, 2.2), rng.uniform(-0.2, 0.9)
        d = np.array([math.sin(u) * math.sqrt(1 - v * v), v, -math.cos(u) * math.sqrt(1 - v * v)])
        if d[2] < -0.5 and abs(d[0]) < 0.6:
            continue  # keep the face clear
        m.ball(rgb(255, 250, 220), head + d * [0.6, 0.5, 0.5], 0.025, subdiv=0)
    # glowing cyan eyes (slit pupils)
    for s in (-1, 1):
        c = head + [s * 0.22, 0.05, -0.42]
        R = rot(0, -s * 20, 0)
        m.ball(rgb(150, 255, 230), c, [0.13, 0.11, 0.07], R, subdiv=2)
        m.ball(rgb(20, 60, 60), c + R @ [0, 0, -0.05], [0.025, 0.09, 0.03], R, subdiv=1)
        m.ball(WHITE, c + R @ [-s * 0.05, 0.05, -0.065], 0.02, subdiv=0)
    m.ball(rgb(255, 140, 200), head + [0, -0.12, -0.5], [0.06, 0.045, 0.04], subdiv=1)
    wh = m.group(rgb(200, 180, 255), min_tris=80)
    for s in (-1, 1):
        for k in (-1, 1):
            wh.add(capsule(head + [s * 0.3, -0.15 + k * 0.04, -0.38], head + [s * 0.72, -0.12 + k * 0.1, -0.3], 0.012))
    # star tip on the tail
    tip = np.array(tp[-1]) + [-0.05, 0.12, 0.05]
    st = m.group(rgb(255, 235, 120), min_tris=150)
    for k in range(5):
        a = k / 5 * 2 * math.pi
        st.add(cone(tip, tip + [math.sin(a) * 0.22, math.cos(a) * 0.22, 0], 0.07, 0.01))
    st.inter(rbox(tip, (0.3, 0.3, 0.06), r=0.03))
    # a small moon
    moon = m.group(rgb(240, 240, 225), min_tris=400)
    mc = np.array([-1.15, 2.5, 0.35])
    moon.add(sphere(mc, 0.3))
    for p, r in (((0.1, 0.1, -0.28), 0.08), ((-0.12, -0.08, -0.27), 0.06), ((0.05, -0.18, -0.25), 0.05)):
        moon.sub(sphere(mc + p, r), k=0.02)
    return m


@boss("zoomzola")
def b_zoomzola():
    m = Model("boss_zoomzola", BUDGET_BOSS, radius=1.0)
    cheese = rgb(230, 235, 245)
    rind = rgb(205, 200, 170)
    vein = rgb(90, 120, 170)
    wc = np.array([0, 1.45, 0.0])
    Rw = rot(0, 0, 90)  # wheel axis along X: rolls toward -Z
    w = m.group(cheese, min_tris=1800)
    w.add(cyl(wc, 0.85, 1.05, Rw, round_=0.12))
    w.sub(sphere(wc + [0.42, 0.55, 0.45], 0.14), k=0.03)
    w.sub(sphere(wc + [-0.42, -0.35, 0.6], 0.11), k=0.03)
    r = m.group(rind, min_tris=500)
    r.add(torus(wc + [0.42, 0, 0], 0.96, 0.06, Rw))
    r.add(torus(wc + [-0.42, 0, 0], 0.96, 0.06, Rw))
    # blue veins wandering over the faces and tread
    v = m.group(vein, min_tris=900)
    rng = _rng(5)
    for s in (-1, 1):
        for k in range(4):
            a0 = rng.uniform(0, 2 * math.pi)
            pts = []
            for i in range(5):
                a = a0 + i * 0.35
                rr = 0.35 + 0.45 * (i / 4) + 0.08 * math.sin(i * 2.1 + k)
                pts.append(wc + [s * 0.43, math.cos(a) * rr, math.sin(a) * rr])
            v.add(tube(pts, 0.035))
    for k in range(5):
        a = k / 5 * 2 * math.pi + 0.3
        pts = [wc + [x, math.cos(a + x * 0.8) * 1.05, math.sin(a + x * 0.8) * 1.05] for x in np.linspace(-0.3, 0.3, 4)]
        v.add(tube(pts, 0.03))
    v.inter(cyl(wc, 0.87, 1.075, Rw, round_=0.12))
    # face on the leading tread (front, -Z)
    face_c = wc + [0, 0.1, -1.0]
    big_eyes(m, 0.2, face_c[1] + 0.12, face_c[2] - 0.0, 0.14, rgb(90, 140, 255), yaw=6, depth=0.6)
    mouth = m.group(rgb(90, 40, 50), min_tris=120)
    mouth.add(ell(face_c + [0, -0.3, 0.0], (0.25, 0.11, 0.08)))
    mouth.inter(plane((0, 1, 0), face_c[1] - 0.3 + 0.0), k=0.02)
    tongue = m.group(rgb(240, 110, 130), min_tris=60)
    tongue.add(ell(face_c + [0.03, -0.37, -0.05], (0.11, 0.05, 0.05)))
    brow = m.group(vein, min_tris=60)
    brow.add(sym(capsule(face_c + [0.08, 0.34, -0.03], face_c + [0.32, 0.4, 0.0], 0.03)))
    # little legs + running sneakers
    legs = m.group(rgb(245, 220, 180), min_tris=200)
    shoe = m.group(rgb(240, 60, 60), min_tris=500)
    sole = m.group(WHITE, min_tris=250)
    for s, ph in ((-1, 1), (1, -1)):
        hip = np.array([s * 0.28, 0.65, 0.0])
        foot = np.array([s * 0.3, 0.17, ph * 0.3])
        legs.add(capsule(hip, foot + [0, 0.1, 0], 0.07))
        shoe.add(ell(foot + [0, 0.06, -0.08], (0.15, 0.12, 0.26)))
        sole.add(ell(foot + [0, -0.03, -0.08], (0.16, 0.05, 0.27)))
        sole.add(ell(foot + [0, 0.1, -0.26], (0.09, 0.06, 0.07)), k=0.02)
    # speed lines + green stink cloud trail
    sl = m.group(rgb(200, 230, 255), min_tris=200)
    for y, z, x in ((1.9, 1.3, 0.3), (1.4, 1.45, -0.35), (0.95, 1.25, 0.25)):
        sl.add(capsule((x, y, z), (x, y, z + 0.6), 0.04))
    cl = m.group(rgb(150, 200, 110), min_tris=500)
    for p, r_ in (((0, 0.45, 1.15), 0.28), ((0.25, 0.6, 1.4), 0.22), ((-0.2, 0.35, 1.5), 0.2), ((0.05, 0.75, 1.65), 0.16)):
        cl.add(sphere(p, r_), k=0.12)
    return m


# champions ------------------------------------------------------------------
# Bipedal hero-mice, designed at ChampionModels.UNIT_RADIUS (2.4), facing -Z.
# Names are the champion ids themselves (they already carry the champ_ prefix).


def champ(name):
    return model(name, BUDGET_CHAMP, "champ")


def biped(m: Model, fur, belly, ear=1.0, snout=1.0, torso=True, tail=True, arms=True):
    """The shared hero-mouse body (ChampionModels.mouseBody proportions).
    Returns the head centre."""
    dark = lerp_c(fur, EYE, 0.25)
    hy, hz = 3.75, -0.15
    head = np.array([0, hy, hz])
    b = m.group(fur, min_tris=1800)
    b.add(ell(head, (0.95, 0.85, 0.82)))
    b.add(sym(ell(head + [0.5, -0.3, -0.45], (0.32, 0.26, 0.3))), k=0.15)  # cheeks
    b.add(sym(capsule((0.5, 1.3, 0.1), (0.55, 0.35, 0.05), 0.3)), k=0.1)  # legs
    if torso:
        b.add(ell((0, 2.15, 0.1), (0.98, 1.05, 0.82)), k=0.25)
        b.add(sphere((0, 2.95, 0.05), 0.4), k=0.4)  # neck blend
    if arms:
        b.add(sym(tube([(0.9, 2.75, 0.05), (1.15, 2.2, 0.0), (1.17, 1.8, -0.05)], [0.27, 0.24, 0.22])), k=0.12)
    feet = m.group(dark, min_tris=200)
    feet.add(sym(ell((0.58, 0.2, -0.15), (0.39, 0.22, 0.55))))
    bel = m.group(belly, min_tris=500)
    if torso:
        bel.add(ell((0, 2.05, -0.36), (0.68, 0.76, 0.42)))
    mz = hz - 0.78 - 0.12 * snout
    bel.add(ell((0, hy - 0.28, mz + 0.12), (0.48, 0.34, 0.38 * snout)), k=0.05)
    if arms:
        bel.add(sym(sphere((1.17, 1.62, -0.08), 0.29)))  # hands
    m.ball(PINK_DARK, (0, hy - 0.12, mz - 0.26 * snout), [0.16, 0.13, 0.13], subdiv=2)
    teeth = m.group(WHITE, min_tris=40)
    teeth.add(rbox((0, hy - 0.52, mz - 0.12 * snout), (0.11, 0.09, 0.04), r=0.025))
    m.sym_ball(PINK, (0.6, hy - 0.22, hz - 0.62), [0.18, 0.1, 0.06], rot(0, -30, 0), subdiv=1)
    bead_eyes(m, 0.36, hy + 0.15, hz - 0.68, 0.19)
    # ears
    e = ear * 1.1
    ec = np.array([0.62, hy + 0.55 + e * 0.15, hz + 0.1])
    R = rot(-6, -12, -22)
    ears = m.group(lerp_c(fur, PINK, 0.15), min_tris=300)
    ears.add(sym(ell(ec, (e * 0.55, e * 0.52, 0.11), R)))
    inner = m.group(PINK, min_tris=150)
    inner.add(sym(ell(ec + R @ np.array([0, -0.03, -0.065]), (e * 0.4, e * 0.37, 0.06), R)))
    if tail:
        tl = m.group(PINK, min_tris=150)
        tl.add(tube([(0, 1.5, 0.75), (0, 1.25, 1.4), (0.15, 1.5, 2.0), (0.2, 2.1, 2.2), (0.1, 2.5, 2.0)], [0.14, 0.12, 0.1, 0.08, 0.06]))
    return head


@champ("champ_captain")
def c_captain():
    m = Model("champ_captain", BUDGET_CHAMP, radius=2.4)
    fur = rgb(150, 132, 118)
    head = biped(m, fur, rgb(236, 220, 200), ear=1.05)
    steel = STEEL
    arm = m.group(steel, min_tris=800)
    arm.add(ell((0, 2.25, 0.05), (1.02, 0.85, 0.86)))
    arm.inter(plane((0, -1, 0), -1.55), k=0.05)
    arm.add(sym(ell((0.95, 2.85, 0.05), (0.42, 0.25, 0.42), rot(0, 0, -20))), k=0.05)  # pauldrons
    belt = m.group(rgb(110, 70, 40), min_tris=200)
    belt.add(torus((0, 1.55, 0.08), 0.92, 0.1))
    m.ball(GOLD, (0, 1.56, -0.86), [0.17, 0.14, 0.06], subdiv=1)
    emb = m.group(rgb(200, 40, 45), min_tris=120)
    emb.add(ell((0, 2.35, -0.83), (0.28, 0.32, 0.06), rot(-8, 0, 0)))
    # helmet with a red plume
    hel = m.group(steel, min_tris=500)
    hel.add(ell(head + [0, 0.25, 0.08], (0.98, 0.7, 0.86)))
    hel.sub(ell(head + [0, -0.2, -0.5], (0.95, 0.75, 0.6)), k=0.06)
    hel.sub(plane((0, -1, 0), -(head[1] + 0.05)))
    plume = m.group(rgb(235, 55, 60), min_tris=300)
    plume.add(tube([head + [0, 0.85, -0.3], head + [0, 1.25, 0.1], head + [0, 1.2, 0.6], head + [0, 0.85, 0.95]], [0.12, 0.2, 0.17, 0.08]))
    # red cape
    cape = m.group(rgb(200, 35, 45), min_tris=400)
    cape.add(rbox((0, 1.85, 0.95), (0.95, 1.05, 0.06), r=0.05, R=rot(8, 0, 0)))
    cape.add(capsule((-0.8, 2.85, 0.6), (0.8, 2.85, 0.6), 0.1), k=0.1)
    # round shield on the left arm
    sh = np.array([-1.45, 2.05, -0.25])
    Rs = rot(0, 70, 0) @ rot(90, 0, 0)
    shield = m.group(rgb(200, 40, 45), min_tris=400)
    shield.add(cyl(sh, 0.12, 0.72, Rs, round_=0.05))
    rim = m.group(steel, min_tris=300)
    rim.add(torus(sh, 0.7, 0.07, Rs))
    m.ball(GOLD, sh + Rs @ np.array([0, -0.08, 0]), [0.22, 0.1, 0.22], Rs, subdiv=1)
    # sword in the right hand
    hand = np.array([1.17, 1.62, -0.08])
    blade = m.group(rgb(225, 232, 240), min_tris=200)
    up = np.array([0, 0.95, -0.3])
    up = up / np.linalg.norm(up)
    blade.add(cone(hand + up * 0.45, hand + up * 2.6, 0.12, 0.02))
    blade.inter(rbox(hand + up * 1.5, (0.2, 1.4, 0.05), r=0.02, R=rot(-17.5, 0, 0)))
    guard = m.group(GOLD, min_tris=150)
    guard.add(capsule(hand + up * 0.42 + [-0.35, 0, 0], hand + up * 0.42 + [0.35, 0, 0], 0.07))
    guard.add(sphere(hand - up * 0.35, 0.1))
    grip = m.group(rgb(90, 60, 40), min_tris=60)
    grip.add(capsule(hand - up * 0.3, hand + up * 0.38, 0.07))
    # moustache
    mo = m.group(rgb(80, 60, 50), min_tris=100)
    mo.add(sym(tube([head + [0.05, -0.42, -1.0], head + [0.3, -0.4, -0.92], head + [0.45, -0.3, -0.82]], [0.07, 0.06, 0.03])))
    return m


@champ("champ_golem")
def c_golem():
    m = Model("champ_golem", BUDGET_CHAMP, radius=2.4)
    cheese = rgb(255, 204, 70)
    rind = rgb(236, 160, 40)
    hole = rgb(206, 140, 30)
    b = m.group(cheese, min_tris=2500)
    torso = np.array([0, 2.4, 0.05])
    b.add(rbox(torso, (1.15, 0.95, 0.85), r=0.3))
    head = np.array([0, 3.85, -0.05])
    b.add(rbox(head, (0.65, 0.55, 0.6), r=0.25), k=0.1)
    for s in (-1, 1):
        b.add(rbox((s * 1.45, 2.3, 0.0), (0.38, 0.75, 0.42), r=0.18, R=rot(0, 0, s * 8)), k=0.1)  # arms
        b.add(rbox((s * 1.6, 1.25, -0.1), (0.48, 0.42, 0.48), r=0.2), k=0.05)  # fists
        b.add(rbox((s * 0.55, 0.65, 0.05), (0.38, 0.65, 0.42), r=0.18), k=0.08)  # legs
    holes = [((0.6, 2.7, -0.85), 0.24), ((-0.5, 2.1, -0.85), 0.3), ((0.2, 1.75, -0.85), 0.15), ((-0.8, 2.9, -0.7), 0.13),
             ((1.1, 2.0, 0.6), 0.2), ((-1.0, 2.6, 0.7), 0.25), ((0.35, 4.2, -0.62), 0.12), ((-1.6, 1.4, -0.55), 0.14), ((1.45, 2.6, -0.4), 0.12)]
    for p, r in holes:
        b.sub(sphere(p, r), k=0.05)
    rd = m.group(rind, min_tris=500)
    rd.add(rbox(torso + [0, -0.85, 0], (1.17, 0.12, 0.87), r=0.1))
    rd.add(sym(rbox((0.55, 0.12, -0.05), (0.42, 0.13, 0.52), r=0.08)))
    hl = m.group(hole, min_tris=400)
    for p, r in holes:
        hl.add(sphere(p, r * 0.92))
    hl.inter(union(rbox(torso, (1.15, 0.95, 0.85), r=0.3), rbox(head, (0.65, 0.55, 0.6), r=0.25),
                   rbox((1.45, 2.3, 0.0), (0.38, 0.75, 0.42), r=0.18), rbox((-1.6, 1.25, -0.1), (0.48, 0.42, 0.48), r=0.2), rbox((1.6, 1.25, -0.1), (0.48, 0.42, 0.48), r=0.2)))
    # glowing eyes + angry brow + core
    for s in (-1, 1):
        m.ball(rgb(255, 90, 30), head + [s * 0.3, 0.0, -0.58], [0.15, 0.12, 0.08], subdiv=2)
        m.ball(rgb(255, 230, 160), head + [s * 0.27, 0.04, -0.64], 0.04, subdiv=0)
    br = m.group(rgb(120, 70, 20), min_tris=100)
    br.add(sym(capsule(head + [0.08, 0.22, -0.6], head + [0.48, 0.3, -0.56], 0.06)))
    br.add(capsule(head + [-0.25, -0.3, -0.62], head + [0.25, -0.3, -0.62], 0.05))
    m.ball(rgb(255, 120, 40), torso + [0.62, 0.35, -0.88], [0.16, 0.16, 0.08], subdiv=2)
    # mouse ears on top: it's still a mouse golem
    ears = m.group(rind, min_tris=200)
    ears.add(sym(ell(head + [0.55, 0.55, 0.1], (0.35, 0.33, 0.1), rot(0, -10, -20))))
    return m


@champ("champ_ratking")
def c_ratking():
    m = Model("champ_ratking", BUDGET_CHAMP, radius=2.4)
    fur = rgb(120, 110, 112)
    head = biped(m, fur, rgb(210, 196, 190), ear=0.85, snout=1.45, torso=False)
    robe = rgb(110, 40, 150)
    r = m.group(robe, min_tris=1200)
    r.add(cone((0, 0.35, 0.1), (0, 2.9, 0.05), 1.15, 0.7))
    r.inter(plane((0, -1, 0), -0.12), k=0.04)
    r.add(sphere((0, 2.95, 0.05), 0.55), k=0.4)
    r.add(sym(tube([(0.9, 2.75, 0.05), (1.15, 2.2, 0.0), (1.2, 1.85, -0.05)], [0.3, 0.3, 0.32])), k=0.12)  # sleeves
    trim = m.group(rgb(250, 248, 240), min_tris=500)
    trim.add(ell((0, 3.0, 0.05), (1.15, 0.33, 0.95)))  # ermine collar
    trim.add(torus((0, 0.32, 0.1), 1.08, 0.1))
    trim.add(rbox((0, 1.4, -0.95), (0.18, 1.05, 0.05), r=0.04, R=rot(-11, 0, 0)))
    for p in ((0.5, 3.1, -0.75), (-0.45, 3.05, -0.78), (0.95, 3.05, 0.0), (-0.95, 3.05, 0.1), (0, 1.9, -1.05), (0, 1.0, -1.2)):
        m.ball(EYE, p, [0.05, 0.08, 0.04], subdiv=0)
    m.sym_ball(rgb(250, 248, 240), (1.2, 1.78, -0.05), [0.34, 0.12, 0.34], subdiv=1)  # cuffs
    # crown with gems
    cr = m.group(GOLD, min_tris=500)
    cc = head + [0, 0.75, 0.0]
    cr.add(cyl(cc, 0.32, 0.5, round_=0.04))
    cr.sub(cyl(cc + [0, 0.06, 0], 0.32, 0.43, round_=0.02))
    for i in range(6):
        a = i / 6 * 2 * math.pi
        cr.add(cone(cc + [math.sin(a) * 0.46, 0.1, math.cos(a) * 0.46], cc + [math.sin(a) * 0.5, 0.45, math.cos(a) * 0.5], 0.09, 0.03), k=0.03)
        m.ball(rgb(230, 40, 60) if i % 2 == 0 else rgb(60, 140, 255), cc + [math.sin(a + 0.52) * 0.5, 0.0, math.cos(a + 0.52) * 0.5], 0.07, subdiv=1)
    # orb sceptre in the right hand
    hand = np.array([1.2, 1.62, -0.1])
    st = m.group(GOLD, min_tris=200)
    st.add(capsule(hand + [0, -1.4, 0], hand + [0, 1.6, 0], 0.07))
    st.add(torus(hand + [0, 1.65, 0], 0.18, 0.05))
    m.ball(rgb(170, 90, 255), hand + [0, 2.0, 0], 0.34, subdiv=2)
    m.ball(rgb(230, 200, 255), hand + [-0.1, 2.12, -0.24], 0.07, subdiv=0)
    return m


@champ("champ_sniper")
def c_sniper():
    m = Model("champ_sniper", BUDGET_CHAMP, radius=2.4)
    fur = rgb(170, 140, 110)
    head = biped(m, fur, rgb(240, 225, 200), ear=0.95, snout=1.1)
    hood = rgb(70, 110, 60)
    h = m.group(hood, min_tris=800)
    h.add(ell(head + [0, 0.15, 0.15], (1.02, 0.95, 0.9)))
    h.sub(ell(head + [0, -0.15, -0.55], (0.9, 0.85, 0.7)), k=0.08)
    h.add(ell((0, 2.9, 0.15), (1.1, 0.35, 0.9)), k=0.2)  # hood shoulders
    h.add(cone(head + [0, 0.4, 0.7], head + [0, -0.2, 1.3], 0.35, 0.05), k=0.15)  # hood tip
    vest = m.group(lerp_c(hood, EYE, 0.25), min_tris=500)
    vest.add(ell((0, 2.15, 0.12), (1.02, 0.92, 0.86)))
    vest.sub(ell((0, 2.2, -0.75), (0.45, 0.85, 0.3)), k=0.05)
    vest.inter(plane((0, -1, 0), -1.45))
    strap = m.group(rgb(110, 75, 45), min_tris=200)
    strap.add(torus((0, 2.2, 0.1), 0.98, 0.08, rot(0, 0, 40)))
    scarf = m.group(rgb(200, 70, 50), min_tris=300)
    scarf.add(torus((0, 3.05, 0.0), 0.62, 0.15))
    scarf.add(tube([(0.3, 3.0, 0.55), (0.45, 2.6, 0.85), (0.55, 2.2, 0.95)], [0.12, 0.1, 0.07]), k=0.05)
    # long rifle held across, with a glinting scope
    hand = np.array([1.17, 1.62, -0.08])
    d = np.array([-0.15, 0.25, -1.0])
    d = d / np.linalg.norm(d)
    stock = m.group(rgb(110, 70, 40), min_tris=200)
    stock.add(rbox(hand + d * 0.1 + [0, 0, 0.3], (0.15, 0.25, 0.6), r=0.08, R=rot(-14, -8, 0)))
    barrel = m.group(rgb(70, 72, 80), min_tris=300)
    barrel.add(capsule(hand + d * 0.2 + [0, 0.1, 0], hand + d * 3.2 + [0, 0.1, 0], 0.08))
    barrel.add(capsule(hand + d * 0.6 + [0, 0.42, 0], hand + d * 1.5 + [0, 0.42, 0], 0.13), k=0.03)
    m.ball(rgb(140, 220, 255), hand + d * 1.6 + [0, 0.42, 0], [0.12, 0.12, 0.05], subdiv=1)
    # leaf camo on the hood
    leaf = m.group(rgb(90, 150, 60), min_tris=300)
    for p in ((0.5, 0.75, -0.2), (-0.6, 0.65, 0.0), (0.0, 0.95, 0.2), (0.7, 0.2, 0.4)):
        leaf.add(ell(head + p, (0.22, 0.07, 0.13), rot(20, p[0] * 40, 30)))
    leaf.inter(ell(head + [0, 0.15, 0.15], (1.07, 1.0, 0.95)))
    return m


@champ("champ_chemist")
def c_chemist():
    m = Model("champ_chemist", BUDGET_CHAMP, radius=2.4)
    fur = rgb(176, 168, 186)
    head = biped(m, fur, rgb(236, 226, 232), ear=1.0)
    coat = m.group(rgb(250, 252, 255), min_tris=900)
    coat.add(ell((0, 2.2, 0.1), (1.08, 1.1, 0.9)))
    coat.add(cone((0, 1.9, 0.1), (0, 0.75, 0.15), 0.95, 1.05), k=0.2)
    coat.inter(plane((0, -1, 0), -0.7))
    coat.sub(rbox((0, 1.2, -1.0), (0.2, 0.55, 0.3), r=0.05), k=0.05)
    coat.add(sym(tube([(0.9, 2.75, 0.05), (1.15, 2.2, 0.0), (1.2, 1.85, -0.05)], [0.3, 0.29, 0.3])), k=0.12)
    for i in range(3):
        m.ball(rgb(100, 110, 130), (0.18, 2.6 - i * 0.42, -0.98 + i * 0.02), [0.07, 0.07, 0.04], subdiv=1)
    belt = m.group(rgb(90, 60, 40), min_tris=200)
    belt.add(torus((0, 1.45, 0.1), 0.98, 0.09))
    # flasks on the belt
    for i, c in enumerate((rgb(120, 255, 120), rgb(255, 90, 200), rgb(255, 230, 80))):
        a = math.radians(-50 + i * 50)
        p = np.array([math.sin(a) * 1.05, 1.25, 0.1 - math.cos(a) * 0.95])
        g = m.group(c, min_tris=120)
        g.add(sphere(p, 0.2))
        g.add(capsule(p, p + [0, 0.3, 0], 0.08), k=0.04)
        m.ball(rgb(150, 110, 70), p + [0, 0.38, 0], [0.08, 0.06, 0.08], subdiv=1)
    # goggles on the forehead
    gs = m.group(rgb(60, 50, 50), min_tris=200)
    gs.add(torus(head + [0, 0.42, 0.05], 0.86, 0.08, rot(-12, 0, 0)))
    gg = m.group(rgb(150, 110, 60), min_tris=300)
    for s in (-1, 1):
        gg.add(cyl(head + [s * 0.36, 0.55, -0.72], 0.22, 0.27, rot(80, 0, 0), round_=0.05))
        m.ball(rgb(120, 255, 140), head + [s * 0.36, 0.53, -0.84], [0.2, 0.2, 0.05], subdiv=1)
    # held flask, bubbling
    hand = np.array([1.2, 1.62, -0.1])
    fl = m.group(rgb(140, 255, 120), min_tris=300)
    fl.add(sphere(hand + [0, 0.58, -0.1], 0.45))
    fl.add(cyl(hand + [0, 1.1, -0.1], 0.45, 0.18, round_=0.04), k=0.08)
    glass = m.group(rgb(200, 230, 210), min_tris=120)
    glass.add(torus(hand + [0, 1.3, -0.1], 0.19, 0.05))
    for i, p in enumerate(((0.05, 1.5, -0.1), (-0.08, 1.75, -0.05), (0.1, 1.98, -0.12))):
        m.ball(rgb(160, 255, 140), hand + p, 0.07 + 0.02 * (2 - i), subdiv=1)
    m.ball(WHITE, hand + [-0.18, 0.75, -0.48], 0.07, subdiv=0)
    # wild tuft of hair
    tuft = m.group(rgb(245, 245, 250), min_tris=200)
    for a in (-30, 0, 30):
        tuft.add(cone(head + [0, 0.75, 0.0], head + [math.sin(math.radians(a)) * 0.4, 1.2, 0.15], 0.15, 0.04), k=0.05)
    return m


@champ("champ_thunder")
def c_thunder():
    m = Model("champ_thunder", BUDGET_CHAMP, radius=2.4)
    fur = rgb(240, 170, 70)
    cream = rgb(255, 236, 200)
    b = m.group(fur, min_tris=2500)
    c = np.array([0, 2.3, 0.1])
    b.add(sphere(c, 1.45))
    # spiky fur: cones radiating from the ball (deterministic directions)
    k = 0
    for i in range(7):
        for j in range(10):
            th = math.radians(20 + i * 22)
            ph = j / 10 * 2 * math.pi + i * 0.3
            d = np.array([math.sin(th) * math.sin(ph), math.cos(th), math.sin(th) * math.cos(ph)])
            if d[2] < -0.55 and d[1] > -0.4:
                continue  # keep the face clear
            k += 1
            b.add(cone(c + d * 1.2, c + d * 1.85, 0.32, 0.04), k=0.12)
    b.add(sym(ell((0.55, 0.45, -0.05), (0.32, 0.45, 0.35))), k=0.15)  # feet stubs
    b.add(sym(ell((1.4, 2.0, -0.45), (0.28, 0.28, 0.28))), k=0.1)  # paws
    face = m.group(cream, min_tris=600)
    face.add(ell(c + [0, -0.15, -1.15], (0.95, 0.9, 0.5)))
    face.add(ell(c + [0, -0.45, -1.35], (0.42, 0.3, 0.3)), k=0.08)
    m.ball(PINK_DARK, c + [0, -0.3, -1.65], [0.14, 0.11, 0.1], subdiv=2)
    bead_eyes(m, 0.42, c[1] + 0.15, c[2] - 1.5, 0.2)
    m.sym_ball(rgb(255, 120, 120), c + [0.65, -0.3, -1.38], [0.2, 0.12, 0.06], rot(0, -35, 0), subdiv=1)
    mouth = m.group(MOUTH, min_tris=60)
    mouth.add(ell(c + [0, -0.68, -1.4], (0.2, 0.1, 0.1)))
    ears = m.group(lerp_c(fur, PINK, 0.3), min_tris=200)
    ears.add(sym(ell(c + [0.75, 1.15, -0.4], (0.32, 0.3, 0.12), rot(-10, -15, -30))))
    feet = m.group(lerp_c(fur, EYE, 0.25), min_tris=150)
    feet.add(sym(ell((0.6, 0.18, -0.35), (0.35, 0.2, 0.45))))
    # lightning bolts crackling around
    bolt = m.group(rgb(255, 235, 60), min_tris=500)
    for a, y in ((50, 3.6), (200, 3.3), (310, 1.3), (130, 1.1)):
        r = math.radians(a)
        base = np.array([math.sin(r) * 1.9, y, math.cos(r) * 1.9])
        out = np.array([math.sin(r), 0, math.cos(r)])
        side = np.cross(out, [0, 1, 0])
        pts = [base + [0, 0.55, 0], base + side * 0.2 + [0, 0.1, 0], base - side * 0.12 + [0, 0.05, 0], base + side * 0.1 + [0, -0.5, 0]]
        bolt.add(tube(pts, [0.07, 0.08, 0.08, 0.02]))
    return m


# hero -----------------------------------------------------------------------


@model("hero_elephant", BUDGET_HERO, "hero")
def h_elephant():
    """A neutral chibi elephant body (BotModel.body proportions, herd grey, no
    class gear / sash) for a future elephant suit."""
    m = Model("hero_elephant", BUDGET_HERO, radius=2.25)
    skin = rgb(154, 163, 173)  # #9AA3AD herd grey
    dark = rgb(128, 136, 148)
    light = lerp_c(skin, WHITE, 0.15)
    ear_in = rgb(242, 167, 181)
    tusk = rgb(250, 246, 232)
    b = m.group(skin, min_tris=2000)
    b.add(ell((0, 3.45, 0.4), (2.25, 1.95, 2.8)))
    head = np.array([0, 5.4, -2.95])
    b.add(sphere(head, 2.05), k=0.6)
    b.add(ell((0, 4.55, -3.45), (1.85, 1.15, 1.2)), k=0.4)  # cheeks
    for side in (-1, 1):
        for front in (-1, 1):
            x, z = side * 1.35, (-1.5 if front < 0 else 1.9)
            b.add(cone((x, 2.6, z), (x, 0.45, z), 0.82, 0.78), k=0.3)
    # trunk curling up at the tip
    b.add(tube([(0, 4.35, -4.75), (0, 3.7, -5.05), (0, 3.0, -5.2), (0, 2.45, -5.4), (0, 2.25, -5.85), (0, 2.45, -6.2)], [0.68, 0.6, 0.52, 0.45, 0.38, 0.34]), k=0.3)
    b.add(tube([(0, 3.45, 3.4), (0, 2.9, 4.0)], [0.18, 0.14]), k=0.15)  # tail
    tuft = m.group(dark, min_tris=60)
    tuft.add(ell((0, 2.75, 4.1), (0.27, 0.42, 0.27)))
    feet = m.group(dark, min_tris=300)
    for side in (-1, 1):
        for front in (-1, 1):
            x, z = side * 1.35, (-1.5 if front < 0 else 1.9)
            feet.add(cyl((x, 0.22, z - 0.05), 0.45, 0.88, round_=0.12))
    nails = m.group(tusk, min_tris=150)
    for side in (-1, 1):
        for k in (-1, 0, 1):
            nails.add(sphere((side * 1.35 + k * 0.42, 0.26, -2.28), 0.18))
    belly = m.group(light, min_tris=300)
    belly.add(ell((0, 2.75, 0.1), (1.85, 1.35, 2.25)))
    tip = m.group(dark, min_tris=60)
    tip.add(cyl((0, 2.55, -6.25), 0.25, 0.38, rot(-70, 0, 0), round_=0.08))
    # ears: big rounded flaps with pink insides
    ears = m.group(skin, min_tris=500)
    inner = m.group(ear_in, min_tris=250)
    for side in (-1, 1):
        R = rot(0, side * -30, side * 12)
        c = np.array([side * 2.65, 5.05, -2.45])
        ears.add(ell(c, (1.75, 2.0, 0.21), R))
        inner.add(ell(c + R @ np.array([0, -0.12, -0.14]), (1.3, 1.5, 0.12), R))
    # glossy eyes with two glints, blush, brows
    for side in (-1, 1):
        R = rot(0, side * -12, 0)
        e = np.array([side * 0.82, 5.6, -4.72])
        fwd = R @ np.array([0, 0, -1.0])
        m.ball(WHITE, e, [0.48, 0.6, 0.25], R, subdiv=2)
        m.ball(rgb(30, 28, 40), e + fwd * 0.12 + [0, -0.06, 0], [0.33, 0.44, 0.18], R, subdiv=2)
        m.ball(WHITE, e + fwd * 0.3 + [side * -0.14, 0.18, 0], 0.14, subdiv=1)
        m.ball(WHITE, e + fwd * 0.3 + [side * 0.12, -0.2, 0], 0.065, subdiv=0)
        m.ball(ear_in, (side * 1.45, 4.75, -4.25), [0.4, 0.2, 0.12], rot(0, side * -30, 0), subdiv=1)
    brow = m.group(dark, min_tris=100)
    brow.add(sym(ell((0.85, 6.45, -4.35), (0.6, 0.15, 0.25), rot(0, 0, -10))))
    tk = m.group(tusk, min_tris=200)
    for side in (-1, 1):
        R = rot(-55, 0, side * -14)
        base = np.array([side * 0.9, 4.05, -4.55])
        tk.add(cone(base, base + R @ np.array([0, 1.1, 0]), 0.2, 0.09))
    return m


# ---------------------------------------------------------------------------
# CLI


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("names", nargs="*", help="models to build (name or prefix); default all")
    ap.add_argument("--sheet", help="write a preview contact sheet PNG here")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--color-mode", default="texture", choices=["texture", "vertex", "both"])
    ap.add_argument("--manifest", action="store_true", help="add missing entries to assets/models/manifest.json")
    ap.add_argument("--out", default=OUT_DIR)
    args = ap.parse_args()

    names = [n for n in REGISTRY if not args.names or any(n == a or n.startswith(a) for a in args.names)]
    if args.list:
        for n in REGISTRY:
            print(f"{n:28s} {REGISTRY[n][2]:6s} budget {REGISTRY[n][1]}")
        return
    os.makedirs(args.out, exist_ok=True)
    info_path = os.path.join(args.out, "meshes.json")
    info = json.load(open(info_path)) if os.path.exists(info_path) else {}
    built = []
    for n in names:
        fn, budget, kind = REGISTRY[n]
        t0 = time.time()
        m = fn()
        m.budget = budget
        b = m.build()
        if b.tris > budget:
            raise SystemExit(f"{n}: {b.tris} triangles is over the budget {budget}")
        path = os.path.join(args.out, n + ".glb")
        extras = {"Radius": m.radius} if m.radius else {}
        nbytes = b.write_glb(path, args.color_mode, extras)
        sz = b.size()
        info[n] = {
            "kind": kind,
            "path": "meshes/" + n + ".glb",
            "triangles": int(b.tris),
            "bytes": int(nbytes),
            "radius": m.radius,
            "size": [round(float(x), 3) for x in sz],
            "colors": len(b.palette),
        }
        built.append(b)
        print(f"{n:28s} {b.tris:5d} tris  {nbytes / 1024:6.1f} KB  size {sz[0]:.2f} x {sz[1]:.2f} x {sz[2]:.2f}  ({time.time() - t0:.1f}s)")
    info = {k: info[k] for k in sorted(info)}
    with open(info_path, "w") as fh:
        json.dump(info, fh, indent=2)
        fh.write("\n")
    if args.manifest:
        add_manifest(info)
    if args.sheet:
        contact_sheet(built, args.sheet)
        print("sheet:", args.sheet)


def add_manifest(info):
    data = json.load(open(MANIFEST, encoding="utf-8"))
    have = {e["name"] for e in data}
    added = 0
    for n, e in info.items():
        if n in have:
            continue
        data.append(
            {
                "name": n,
                "path": e["path"],
                "type": "Model",
                "description": f"Trunkfall {e['kind']} mesh {n} (procedural, scripts/make-meshes.py)",
            }
        )
        added += 1
    with open(MANIFEST, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    print(f"manifest: +{added} entries")


def contact_sheet(built, path, tile=340, cols=6):
    from PIL import Image, ImageDraw

    from meshkit import render

    rows = math.ceil(len(built) / cols)
    sheet = Image.new("RGB", (cols * tile, rows * (tile + 34)), (250, 250, 252))
    d = ImageDraw.Draw(sheet)
    for i, b in enumerate(built):
        img = render(b, size=tile)
        x, y = (i % cols) * tile, (i // cols) * (tile + 34)
        sheet.paste(img, (x, y))
        d.text((x + 8, y + tile + 4), b.name, fill=(40, 30, 30))
        d.text((x + 8, y + tile + 18), f"{b.tris} tris", fill=(110, 100, 100))
    sheet.save(path)


if __name__ == "__main__":
    main()
