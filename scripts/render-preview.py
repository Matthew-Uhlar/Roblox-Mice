#!/usr/bin/env python3
"""Preview renderer for Trunkfall's built-in-code graphics (R4 Graphics).

    lune run scripts/render-preview.luau <scenesDir>      # export geometry
    python3 scripts/render-preview.py <scenesDir> assets/previews

Draws the JSON scenes written by render-preview.luau with a small numpy +
Pillow software renderer: every Roblox primitive is tessellated (Block, Wedge,
CornerWedge, Ball, Cylinder along X, SpecialMesh-sphere "Egg"), terrain fill
calls are voxelised at 2 studs and drawn as a height field, then polygons are
lit (sun + ambient + hemisphere), fogged with the map's Atmosphere colour,
sorted back to front and painted with alpha. Neon is emissive and glows,
Glass / ForceField are translucent, lights add soft halos. It is a preview,
not Roblox's renderer: the point is to judge layout, colour, density and
silhouettes without Studio.

Writes contact sheets: maps.png, map_<id>.png (overview + gameplay close-up),
lobby.png, bots.png, skins.png, mice.png, bosses.png, portal.png.
"""
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

TERRAIN_DEFAULT = {
    "Grass": (106, 127, 63), "LeafyGrass": (115, 132, 74), "Ground": (102, 92, 59),
    "Rock": (102, 108, 111), "Sand": (143, 126, 95), "Snow": (195, 199, 218),
    "Glacier": (101, 176, 234), "Ice": (129, 194, 224), "Basalt": (30, 30, 37),
    "CrackedLava": (232, 156, 74), "Mud": (58, 46, 36), "Slate": (63, 127, 107),
    "Sandstone": (137, 90, 71), "Salt": (198, 189, 181), "Pebble": (102, 108, 111),
    "Cobblestone": (132, 123, 90), "Limestone": (206, 173, 148), "Asphalt": (115, 123, 107),
    "Concrete": (127, 102, 63), "Brick": (138, 86, 62), "WoodPlanks": (139, 109, 79),
    "Water": (12, 84, 92),
}
MAT_IDS = {}


def mat_id(name):
    if name not in MAT_IDS:
        MAT_IDS[name] = len(MAT_IDS) + 1
    return MAT_IDS[name]


# ----------------------------------------------------------------- geometry

def cf_matrix(c):
    pos = np.array(c[0:3], dtype=float)
    rot = np.array(c[3:12], dtype=float).reshape(3, 3)  # rows: R00 R01 R02 ...
    return pos, rot


def unit_sphere(nu=10, nv=6):
    verts, faces = [], []
    for j in range(nv + 1):
        phi = math.pi * j / nv
        for i in range(nu):
            th = 2 * math.pi * i / nu
            verts.append((math.sin(phi) * math.cos(th), math.cos(phi), math.sin(phi) * math.sin(th)))
    for j in range(nv):
        for i in range(nu):
            a = j * nu + i
            b = j * nu + (i + 1) % nu
            c = (j + 1) * nu + (i + 1) % nu
            d = (j + 1) * nu + i
            faces.append([a, d, c, b])
    return np.array(verts), faces


def unit_cylinder_x(n=12):
    verts, faces = [], []
    for i in range(n):
        th = 2 * math.pi * i / n
        verts.append((-1, math.cos(th), math.sin(th)))
    for i in range(n):
        th = 2 * math.pi * i / n
        verts.append((1, math.cos(th), math.sin(th)))
    for i in range(n):
        j = (i + 1) % n
        faces.append([i, j, n + j, n + i])
    faces.append(list(range(n))[::-1])
    faces.append(list(range(n, 2 * n)))
    return np.array(verts), faces


BOX_V = np.array([(x, y, z) for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)], dtype=float)
# index = 4*(x>0) + 2*(y>0) + (z>0)
BOX_F = [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]
# Roblox WedgePart: full bottom, tall face at +Z, slope rising from front (-Z) to back.
WEDGE_V = np.array([(-1, -1, -1), (1, -1, -1), (1, -1, 1), (-1, -1, 1), (-1, 1, 1), (1, 1, 1)], dtype=float)
WEDGE_F = [[0, 3, 2, 1], [3, 4, 5, 2], [0, 1, 5, 4], [0, 4, 3], [1, 2, 5]]
# CornerWedgePart: full bottom, apex above the (+X, -Z) corner (approximation).
CORNER_V = np.array([(-1, -1, -1), (1, -1, -1), (1, -1, 1), (-1, -1, 1), (1, 1, -1)], dtype=float)
CORNER_F = [[0, 3, 2, 1], [0, 1, 4], [1, 2, 4], [2, 3, 4], [3, 0, 4]]
SPH_V, SPH_F = unit_sphere()
CYL_V, CYL_F = unit_cylinder_x()

SHAPES = {
    "Block": (BOX_V, BOX_F), "Wedge": (WEDGE_V, WEDGE_F), "CornerWedge": (CORNER_V, CORNER_F),
    "Ball": (SPH_V, SPH_F), "Egg": (SPH_V, SPH_F), "Cylinder": (CYL_V, CYL_F),
}


def part_polys(parts):
    """Returns list of (verts(N,3) world, color, mat, transparency) polygons."""
    out = []
    for p in parts:
        shape = p["shape"]
        if shape not in SHAPES:
            shape = "Block"
        size = np.array(p["size"], dtype=float)
        if shape == "Ball":
            size = np.full(3, size.min())
        elif shape == "Cylinder":
            d = min(size[1], size[2])
            size = np.array([size[0], d, d])
        V, F = SHAPES[shape]
        pos, rot = cf_matrix(p["cf"])
        w = (V * (size / 2)) @ rot.T + pos
        for f in F:
            out.append((w[f], p["color"], p["mat"], p.get("t", 0)))
    return out


# ----------------------------------------------------------------- terrain

class Voxels:
    def __init__(self, center, half_xz, y0, y1, res=2.0):
        self.res = res
        self.x0 = center[0] - half_xz
        self.z0 = center[2] - half_xz
        self.y0 = y0
        n = int(2 * half_xz / res)
        self.nx = self.nz = n
        self.ny = int((y1 - y0) / res)
        self.g = np.zeros((self.nx, self.ny, self.nz), dtype=np.int16)

    def _sub(self, lo, hi):
        r = self.res
        i0 = max(0, int(math.floor((lo[0] - self.x0) / r)))
        i1 = min(self.nx, int(math.ceil((hi[0] - self.x0) / r)))
        j0 = max(0, int(math.floor((lo[1] - self.y0) / r)))
        j1 = min(self.ny, int(math.ceil((hi[1] - self.y0) / r)))
        k0 = max(0, int(math.floor((lo[2] - self.z0) / r)))
        k1 = min(self.nz, int(math.ceil((hi[2] - self.z0) / r)))
        if i0 >= i1 or j0 >= j1 or k0 >= k1:
            return None
        xs = self.x0 + (np.arange(i0, i1) + 0.5) * r
        ys = self.y0 + (np.arange(j0, j1) + 0.5) * r
        zs = self.z0 + (np.arange(k0, k1) + 0.5) * r
        X, Y, Z = np.meshgrid(xs, ys, zs, indexing="ij")
        return (slice(i0, i1), slice(j0, j1), slice(k0, k1)), X, Y, Z

    def fill(self, op):
        m = 0 if op["mat"] == "Air" else mat_id(op["mat"])
        kind = op["op"]
        if kind == "ball":
            c = np.array(op["c"]); r = op["r"]
            s = self._sub(c - r, c + r)
            if not s:
                return
            sl, X, Y, Z = s
            mask = (X - c[0]) ** 2 + (Y - c[1]) ** 2 + (Z - c[2]) ** 2 <= r * r
        else:
            pos, rot = cf_matrix(op["cf"])
            if kind == "cyl":
                half = np.array([op["r"], op["h"] / 2, op["r"]])
            else:
                half = np.array(op["size"]) / 2
            ext = np.abs(rot) @ half
            s = self._sub(pos - ext, pos + ext)
            if not s:
                return
            sl, X, Y, Z = s
            P = np.stack([X - pos[0], Y - pos[1], Z - pos[2]], axis=-1)
            L = P @ rot  # world -> local (rot columns are local axes)
            lx, ly, lz = L[..., 0], L[..., 1], L[..., 2]
            if kind == "cyl":
                mask = (lx ** 2 + lz ** 2 <= half[0] ** 2) & (np.abs(ly) <= half[1])
            elif kind == "wedge":
                inb = (np.abs(lx) <= half[0]) & (np.abs(ly) <= half[1]) & (np.abs(lz) <= half[2])
                # slope plane: y <= -h + (z + d) * (2h / 2d)
                mask = inb & (ly <= -half[1] + (lz + half[2]) * (half[1] / half[2]))
            else:
                mask = (np.abs(lx) <= half[0]) & (np.abs(ly) <= half[1]) & (np.abs(lz) <= half[2])
        sub = self.g[sl]
        sub[mask] = m
        self.g[sl] = sub

    def surface(self, water_id):
        """Heightmap of the top non-air cell; water reported separately."""
        g = self.g
        solid = (g > 0) & (g != water_id)
        anyw = (g == water_id)
        ny = self.ny
        idx = np.arange(ny)[None, :, None]
        top_s = np.where(solid, idx, -1).max(axis=1)
        top_w = np.where(anyw, idx, -1).max(axis=1)
        mats = np.take_along_axis(g, np.clip(top_s, 0, ny - 1)[:, None, :], axis=1)[:, 0, :]
        hs = self.y0 + (top_s + 1) * self.res
        hw = self.y0 + (top_w + 1) * self.res
        return hs, mats, top_s >= 0, hw, top_w > top_s


def terrain_polys(scene, center, half, matcolors, water_color):
    ops = scene.get("terrain") or []
    if not ops:
        return []
    vox = Voxels(center, half, -24, 64, 2.0)
    for op in ops:
        vox.fill(op)
    wid = MAT_IDS.get("Water", -5)
    hs, mats, has, hw, water = vox.surface(wid)
    # soften the stair steps a little (keep the flat play area flat)
    hs2 = hs.copy()
    hs2[1:-1, 1:-1] = (hs[1:-1, 1:-1] * 4 + hs[:-2, 1:-1] + hs[2:, 1:-1] + hs[1:-1, :-2] + hs[1:-1, 2:]) / 8
    hs = np.where(np.abs(hs2 - hs) < 1.6, hs2, hs)
    inv = {v: k for k, v in MAT_IDS.items()}
    lut = {}
    for mid, name in inv.items():
        c = matcolors.get(name)
        lut[mid] = tuple(c) if c else tuple(x / 255 for x in TERRAIN_DEFAULT.get(name, (120, 120, 120)))
    out = []
    r = vox.res
    n = vox.nx
    # corner heights: average of 4 neighbouring cells
    H = np.pad(hs, 1, mode="edge")
    corner = (H[:-1, :-1] + H[1:, :-1] + H[:-1, 1:] + H[1:, 1:]) / 4
    for i in range(n):
        x = vox.x0 + i * r
        for k in range(n):
            if not has[i, k]:
                continue
            z = vox.z0 + k * r
            col = lut.get(int(mats[i, k]), (0.5, 0.5, 0.5))
            v = np.array([
                (x, corner[i, k], z), (x, corner[i, k + 1], z + r),
                (x + r, corner[i + 1, k + 1], z + r), (x + r, corner[i + 1, k], z),
            ])
            out.append((v, col, "Terrain", 0))
            if water[i, k]:
                y = hw[i, k] - 0.6
                wv = np.array([(x, y, z), (x, y, z + r), (x + r, y, z + r), (x + r, y, z)])
                out.append((wv, water_color, "Water", 0.25))
    return out


# ----------------------------------------------------------------- render

class Cam:
    def __init__(self, eye, target, fov, w, h):
        self.eye = np.array(eye, float)
        f = np.array(target, float) - self.eye
        f /= np.linalg.norm(f)
        up = np.array([0, 1, 0.0])
        rgt = np.cross(f, up); rgt /= np.linalg.norm(rgt)
        u = np.cross(rgt, f)
        self.f, self.r, self.u = f, rgt, u
        self.w, self.h = w, h
        self.k = (h / 2) / math.tan(math.radians(fov) / 2)

    def project(self, P):
        d = P - self.eye
        zc = d @ self.f
        xc = d @ self.r
        yc = d @ self.u
        zc_safe = np.maximum(zc, 0.05)
        sx = self.w / 2 + xc / zc_safe * self.k
        sy = self.h / 2 - yc / zc_safe * self.k
        return np.stack([sx, sy], -1), zc


def render(polys, lights, cam, sky, sun_dir, ambient, sun_col, fog_col, fog_density, out_size, light_gain=1.0):
    W, H = cam.w, cam.h
    img = Image.new("RGB", (W, H), tuple(int(c * 255) for c in sky[0]))
    # sky gradient
    grad = np.linspace(0, 1, H)[:, None, None]
    top = np.array(sky[0]); bot = np.array(sky[1])
    arr = (top * (1 - grad) + bot * grad) * 255
    img = Image.fromarray(np.repeat(arr, W, axis=1).astype(np.uint8))
    draw = ImageDraw.Draw(img, "RGBA")
    sun = np.array(sun_dir, float); sun /= np.linalg.norm(sun)
    items = []
    for v, col, mat, t in polys:
        if t >= 0.98:
            continue
        a, b = v[1] - v[0], v[2] - v[0]
        nrm = np.cross(a, b)
        ln = np.linalg.norm(nrm)
        if ln < 1e-9:
            if len(v) > 3:
                nrm = np.cross(v[2] - v[0], v[3] - v[0]); ln = np.linalg.norm(nrm)
            if ln < 1e-9:
                continue
        nrm = nrm / ln
        c = v.mean(axis=0)
        view = c - cam.eye
        if mat not in ("Water",) and nrm @ view > 0 and t < 0.05:
            continue  # back face
        if nrm @ view > 0:
            nrm = -nrm
        pts, zc = cam.project(v)
        if (zc < 0.5).any():
            continue
        if pts[:, 0].max() < 0 or pts[:, 0].min() > W or pts[:, 1].max() < 0 or pts[:, 1].min() > H:
            continue
        col = np.array(col, float)
        if mat == "Neon":
            shade = col * 1.25 + 0.15
        else:
            diff = max(0.0, float(nrm @ sun))
            hemi = 0.5 + 0.5 * nrm[1]
            spec = 0.0
            if mat in ("Metal", "Glass", "Ice", "Marble", "DiamondPlate", "Water", "Glacier"):
                hv = sun - view / np.linalg.norm(view)
                hv /= np.linalg.norm(hv)
                spec = max(0.0, float(nrm @ hv)) ** 24 * (0.6 if mat != "Marble" else 0.25)
            shade = col * (np.array(ambient) * (0.55 + 0.45 * hemi) + np.array(sun_col) * diff * 0.9) + spec
        dist = float(np.linalg.norm(view))
        fog = 1 - math.exp(-dist * fog_density)
        shade = shade * (1 - fog) + np.array(fog_col) * fog
        alpha = 1 - t
        if mat in ("Glass",):
            alpha = min(alpha, 0.55)
        if mat == "ForceField":
            alpha = min(alpha, 0.35)
        rgba = tuple(int(max(0, min(1, x)) * 255) for x in shade) + (int(alpha * 255),)
        items.append((float(zc.mean()), [tuple(p) for p in pts], rgba, mat == "Neon"))
    items.sort(key=lambda it: -it[0])
    for _, pts, rgba, _neon in items:
        draw.polygon(pts, fill=rgba)
    # glow: blur the neon + lights layer and add it
    glow = Image.new("RGB", (W, H), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for _, pts, rgba, neon in items:
        if neon:
            gd.polygon(pts, fill=rgba[:3])
    for L in lights:
        pts, zc = cam.project(np.array([L["p"]]))
        if zc[0] < 1:
            continue
        x, y = pts[0]
        rad = max(3, L["range"] * cam.k / zc[0] * 0.12)
        c = tuple(int(v * 255 * min(1, 0.1 + L["brightness"] * 0.08) * light_gain) for v in L["color"])
        gd.ellipse([x - rad, y - rad, x + rad, y + rad], fill=c)
    glow = glow.filter(ImageFilter.GaussianBlur(radius=max(3, W // 140)))
    g = np.asarray(glow).astype(float) * 0.55
    base = np.asarray(img).astype(float)
    out = np.clip(base + g, 0, 255).astype(np.uint8)
    img = Image.fromarray(out)
    return img.resize(out_size, Image.LANCZOS)


# ----------------------------------------------------------------- scenes

def sun_from_clock(clock):
    a = (clock - 6) / 12 * math.pi  # 0 at sunrise, pi at sunset
    if clock < 5.5 or clock > 18.5:  # night: moonlight from above-ish
        return (0.3, 0.8, 0.4), (0.55, 0.6, 0.85)
    y = max(0.15, math.sin(a))
    x = -math.cos(a)
    warm = 1 - y
    return (x, y, 0.45), (1.0, 0.95 - warm * 0.2, 0.85 - warm * 0.35)


def scene_env(scene):
    L = scene.get("lighting") or {}
    sun, sun_col = sun_from_clock(L.get("clock", 14))
    shift = L.get("shift", [1, 1, 1])
    sun_col = tuple(sc * (0.6 + 0.4 * s) for sc, s in zip(sun_col, shift))
    amb = tuple(min(1, a * 0.9 + 0.08) for a in L.get("ambient", [0.55, 0.55, 0.55]))
    bright = L.get("brightness", 2) / 3
    sun_col = tuple(c * (0.55 + 0.25 * bright) for c in sun_col)
    atmo = L.get("atmo") or {"color": [0.8, 0.85, 0.95], "decay": [0.5, 0.6, 0.8], "density": 0.3, "haze": 1}
    fog_col = tuple(atmo["color"])
    clock = L.get("clock", 14)
    night = clock < 5.5 or clock > 18.5
    sky_top = tuple(c * (0.35 if night else 0.85) for c in atmo["decay"])
    sky_bot = tuple(min(1, c * (0.6 if night else 1.0)) for c in atmo["color"])
    dens = 0.0012 + atmo["density"] * 0.0035 + atmo.get("haze", 1) * 0.0004
    return sun, sun_col, amb, fog_col, dens, (sky_top, sky_bot)


def grade(img, scene):
    L = scene.get("lighting") or {}
    g = L.get("grade")
    if not g:
        return img
    a = np.asarray(img).astype(float) / 255
    a = a * np.array(g["tint"])
    lum = a.mean(axis=2, keepdims=True)
    a = lum + (a - lum) * (1 + g["saturation"])
    a = (a - 0.5) * (1 + g["contrast"]) + 0.5
    return Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8))


def render_map(scene, view, size):
    R = scene.get("radius", 140)
    center = scene.get("center", [0, 0, 0])
    sun, sun_col, amb, fog, dens, sky = scene_env(scene)
    lights = scene.get("lights", [])
    w, h = size[0] * 2, size[1] * 2
    if view == "overview":
        dist = R * 2.15
        eye = (center[0], center[1] + dist * math.sin(math.radians(58)), center[2] + dist * math.cos(math.radians(58)))
        cam = Cam(eye, (center[0], 0, center[2] - R * 0.05), 45, w, h)
        dens *= 0.35
    else:
        # gameplay camera: 55 degree pitch, zoom 70, focused near a squad corner
        sz = (scene.get("safeZones") or [{"x": 0, "z": R * 0.5}])
        fx, fz = (sz[2]["x"] * 0.7, sz[2]["z"] * 0.7) if len(sz) > 2 else (0, R * 0.4)
        if scene.get("kind") == "lobby":
            fx, fz = center[0], center[2] - 8
        zoom = 78
        eye = (fx, zoom * math.sin(math.radians(55)), fz + zoom * math.cos(math.radians(55)))
        cam = Cam(eye, (fx, 0, fz), 45, w, h)
    half = (R + 80) if scene.get("kind") == "arena" else 150
    tp = terrain_polys(scene, center, half, scene.get("matColors", {}), (0.2, 0.55, 0.7))
    pp = part_polys(scene["parts"])
    gain = 1.6 - min(1.2, sum(sun_col) / 3)
    img = render(tp + pp, lights, cam, sky, sun, amb, sun_col, fog, dens, size, gain)
    return grade(img, scene)


def render_object(scene, size, yaw=35, pitch=22, scale=1.0):
    pts = []
    for p in scene["parts"]:
        pts.append(p["cf"][0:3])
    P = np.array(pts) if pts else np.zeros((1, 3))
    lo, hi = P.min(axis=0), P.max(axis=0)
    c = (lo + hi) / 2
    ext = max(2.0, float(np.linalg.norm(hi - lo)) / 2 + 2) * scale
    dist = ext / math.tan(math.radians(20)) * 1.05
    yr, pr = math.radians(yaw), math.radians(pitch)
    # front of models is -Z
    eye = (c[0] - math.sin(yr) * math.cos(pr) * dist, c[1] + math.sin(pr) * dist, c[2] - math.cos(yr) * math.cos(pr) * dist)
    w, h = size[0] * 2, size[1] * 2
    cam = Cam(eye, c, 40, w, h)
    ground = []
    gy = 0.0
    gr = ext * 1.4
    n = 24
    ring = np.array([(c[0] + math.cos(i / n * 6.283) * gr, gy - 0.02, c[2] + math.sin(i / n * 6.283) * gr) for i in range(n)])
    ground.append((ring[::-1], (0.62, 0.78, 0.45), "Terrain", 0))
    polys = ground + part_polys(scene["parts"])
    img = render(polys, scene.get("lights", []), cam, ((0.62, 0.78, 0.95), (0.95, 0.93, 0.85)),
                 (0.45, 0.85, -0.55), (0.62, 0.62, 0.66), (1, 0.96, 0.88), (0.9, 0.92, 0.95), 0.0005, size)
    return img


# ----------------------------------------------------------------- sheets

def font(sz):
    for f in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",):
        if os.path.exists(f):
            return ImageFont.truetype(f, sz)
    return ImageFont.load_default()


def sheet(tiles, cols, title, path):
    if not tiles:
        return
    tw, th = tiles[0][1].size
    rows = (len(tiles) + cols - 1) // cols
    head = 44
    S = Image.new("RGB", (cols * tw, rows * (th + 26) + head), (32, 26, 22))
    d = ImageDraw.Draw(S)
    d.text((12, 8), title, fill=(255, 201, 60), font=font(26))
    for i, (label, im) in enumerate(tiles):
        x, y = (i % cols) * tw, head + (i // cols) * (th + 26)
        S.paste(im, (x, y))
        d.text((x + 8, y + th + 3), label, fill=(255, 244, 214), font=font(17))
    S.save(path)
    print("wrote", path)


def load(d, name):
    p = os.path.join(d, name + ".json")
    if not os.path.exists(p):
        return None
    with open(p) as fh:
        return json.load(fh)


def main():
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "assets/previews"
    only = sys.argv[3] if len(sys.argv) > 3 else None
    os.makedirs(out, exist_ok=True)
    maps = ["plains", "forest", "jungle", "beach", "tundra", "volcano", "swamp", "moon", "ocean"]
    if only in (None, "maps") or (only and only in maps):
        tiles = []
        for m in maps:
            if only and only not in ("maps", m):
                continue
            sc = load(src, "map_" + m)
            if not sc:
                continue
            MAT_IDS.clear()
            ov = render_map(sc, "overview", (720, 480))
            MAT_IDS.clear()
            cl = render_map(sc, "close", (720, 480))
            sheet([(m + " overview", ov), (m + " gameplay camera", cl)], 2, "Trunkfall map: " + m, os.path.join(out, "map_" + m + ".png"))
            tiles.append((m, ov.resize((480, 320), Image.LANCZOS)))
        if len(tiles) > 1:
            sheet(tiles, 3, "Trunkfall: the 9 maps (overview)", os.path.join(out, "maps.png"))
    if only in (None, "lobby"):
        sc = load(src, "lobby")
        if sc:
            MAT_IDS.clear()
            sc["radius"] = 60
            ov = render_map(sc, "overview", (720, 480))
            MAT_IDS.clear()
            cl = render_map(sc, "close", (720, 480))
            sheet([("Herd Sanctuary overview", ov), ("lobby camera", cl)], 2, "Trunkfall lobby", os.path.join(out, "lobby.png"))
    if only in (None, "bots"):
        tiles = []
        for f in sorted(os.listdir(src)):
            if f.startswith("bot_"):
                sc = load(src, f[:-5])
                tiles.append((sc["name"], render_object(sc, (360, 320))))
        sheet(tiles, 4, "Bot heroes (BotModel, one per class)", os.path.join(out, "bots.png"))
        tiles = []
        for f in sorted(os.listdir(src)):
            if f.startswith("skin_"):
                sc = load(src, f[:-5])
                tiles.append((sc["name"], render_object(sc, (240, 220), yaw=25, pitch=18)))
        sheet(tiles, 6, "Skin accessories (ClassGear on BotModel)", os.path.join(out, "skins.png"))
    if only in (None, "mice"):
        tiles = []
        for f in sorted(os.listdir(src)):
            if f.startswith("mouse_"):
                sc = load(src, f[:-5])
                lab = f[6:-5]
                tiles.append((lab, render_object(sc, (300, 260), yaw=40, pitch=25)))
        sheet(tiles, 3, "Mice (normal / elite / LOD)", os.path.join(out, "mice.png"))
    if only in (None, "bosses"):
        tiles = []
        for f in sorted(os.listdir(src)):
            if f.startswith("boss_"):
                sc = load(src, f[:-5])
                tiles.append((sc["name"], render_object(sc, (360, 320), yaw=30, pitch=20)))
        sheet(tiles, 4, "Bosses (BossModels)", os.path.join(out, "bosses.png"))
    if only in (None, "portal"):
        sc = load(src, "portal_plains")
        if sc:
            sheet([("Rind Gate portal", render_object(sc, (520, 400), yaw=20, pitch=40))], 1, "Rind Gate", os.path.join(out, "portal.png"))


if __name__ == "__main__":
    main()
