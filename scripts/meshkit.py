"""meshkit: a tiny signed-distance modeller for Trunkfall's "chunky toy" meshes.

Used by scripts/make-meshes.py (see that file and assets/models/PLAN.md).

A Model is a list of colour groups. Each group is one solid colour built from
SDF primitives combined with smooth union / subtraction / intersection, meshed
with marching cubes, lightly Taubin-smoothed and decimated to its share of the
model's triangle budget. Groups of different colours simply interpenetrate
(like painted toy parts), so colour borders are crisp and every vertex carries
exactly one palette colour. Small round details (eye glints) can be added as
low-poly icospheres.

Output (write_glb): one mesh, one material whose baseColorTexture is a tiny
palette PNG (each colour is an 8x8 swatch; every vertex's UV sits in the middle
of its swatch), smooth vertex normals, optional COLOR_0. Coordinates are Roblox
studs, Y up, the model faces -Z, the bounding box is centred on X/Z and its
lowest point is at Y = 0. Everything is deterministic (no randomness unless a
seeded generator is passed in by the caller).

Conventions for designing: X right, Y up, the creature looks toward -Z.
`sym(shape)` mirrors a shape designed on the +X side to both sides.
"""

from __future__ import annotations

import io
import json
import math
import struct

import fast_simplification
import numpy as np
import trimesh
from PIL import Image
from skimage.measure import marching_cubes

# --------------------------------------------------------------------------
# maths helpers


def rot(rx=0.0, ry=0.0, rz=0.0):
    """Rotation matrix from Euler degrees, applied X then Y then Z (like
    CFrame.Angles). Columns are the local axes expressed in world space."""
    ax, ay, az = (math.radians(v) for v in (rx, ry, rz))
    cx, sx, cy, sy, cz, sz = math.cos(ax), math.sin(ax), math.cos(ay), math.sin(ay), math.cos(az), math.sin(az)
    Rx = np.array([[1, 0, 0], [0, cx, -sx], [0, sx, cx]])
    Ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    Rz = np.array([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]])
    return Rx @ Ry @ Rz


def v3(*a):
    if len(a) == 1:
        return np.asarray(a[0], dtype=np.float64)
    return np.asarray(a, dtype=np.float64)


def rgb(r, g, b):
    return (int(r), int(g), int(b))


def lerp_c(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def _len(p):
    return np.sqrt(np.einsum("...i,...i->...", p, p))


def smin(a, b, k):
    if k <= 0:
        return np.minimum(a, b)
    h = np.maximum(k - np.abs(a - b), 0.0) / k
    return np.minimum(a, b) - h * h * k * 0.25


def smax(a, b, k):
    return -smin(-a, -b, k)


# --------------------------------------------------------------------------
# shapes: callables p(N,3) -> distance(N,), with a conservative AABB


class Shape:
    def __init__(self, fn, lo, hi):
        self.fn = fn
        self.lo = np.asarray(lo, dtype=np.float64)
        self.hi = np.asarray(hi, dtype=np.float64)

    def __call__(self, p):
        return self.fn(p)


def _placed(local_fn, c, R, ext):
    """Wrap a local-space SDF; ext = local half-extent (bounding sphere radius
    is used when rotated)."""
    c = v3(c)
    ext = np.asarray(ext, dtype=np.float64)
    if R is None:
        lo, hi = c - ext, c + ext
        return Shape(lambda p: local_fn(p - c), lo, hi)
    Rm = np.asarray(R)
    # rotated AABB of the local box
    e = np.abs(Rm) @ ext
    return Shape(lambda p: local_fn((p - c) @ Rm), c - e, c + e)


def sphere(c, r):
    return _placed(lambda q: _len(q) - r, c, None, [r, r, r])


def ell(c, radii, R=None):
    """Ellipsoid with semi-axes `radii` (local X, Y, Z)."""
    r = v3(radii)

    def f(q):
        k0 = _len(q / r)
        k1 = _len(q / (r * r))
        return k0 * (k0 - 1.0) / np.maximum(k1, 1e-9)

    return _placed(f, c, R, r)


def rbox(c, half, r=0.05, R=None):
    """Rounded box with half-size `half` (outer size), corner radius r."""
    b = v3(half) - r

    def f(q):
        d = np.abs(q) - b
        return _len(np.maximum(d, 0.0)) + np.minimum(d.max(axis=-1), 0.0) - r

    return _placed(f, c, R, v3(half))


def cyl(c, h, r, R=None, round_=0.02):
    """Capped cylinder along local Y, height h, radius r, edges rounded."""

    def f(q):
        dx = np.sqrt(q[:, 0] ** 2 + q[:, 2] ** 2) - r + round_
        dy = np.abs(q[:, 1]) - h / 2 + round_
        d = np.stack([dx, dy], -1)
        return np.minimum(np.maximum(dx, dy), 0.0) + _len(np.maximum(d, 0.0)) - round_

    return _placed(f, c, R, [r, h / 2, r])


def torus(c, R_, r, R=None):
    """Torus around local Y (ring in the local XZ plane)."""

    def f(q):
        a = np.sqrt(q[:, 0] ** 2 + q[:, 2] ** 2) - R_
        return np.sqrt(a * a + q[:, 1] ** 2) - r

    return _placed(f, c, R, [R_ + r, r, R_ + r])


def cone(a, b, ra, rb):
    """Round cone (tapered capsule) from point a (radius ra) to b (radius rb)."""
    a, b = v3(a), v3(b)
    ba = b - a
    l2 = float(ba @ ba)
    rr = ra - rb
    a2 = l2 - rr * rr
    il2 = 1.0 / l2

    def f(p):
        pa = p - a
        y = pa @ ba
        z = y - l2
        w = pa * l2 - np.outer(y, ba)
        x2 = np.einsum("ij,ij->i", w, w)
        y2 = y * y * l2
        z2 = z * z * l2
        k = math.copysign(1.0, rr) * rr * rr * x2
        d_top = np.sqrt(x2 + z2) * il2 - rb
        d_bot = np.sqrt(x2 + y2) * il2 - ra
        d_mid = (np.sqrt(np.maximum(x2 * a2 * il2, 0.0)) + y * rr) * il2 - ra
        return np.where(np.sign(z) * a2 * z2 > k, d_top, np.where(np.sign(y) * a2 * y2 < k, d_bot, d_mid))

    m = max(ra, rb)
    return Shape(f, np.minimum(a, b) - m, np.maximum(a, b) + m)


def capsule(a, b, r):
    return cone(a, b, r, r * 0.9999)


def tube(points, radii):
    """A chain of round cones through `points` with per-point radii (hard
    union: the segments are continuous already)."""
    pts = [v3(p) for p in points]
    if np.isscalar(radii):
        radii = [radii] * len(pts)
    segs = [cone(pts[i], pts[i + 1], radii[i], radii[i + 1] * 0.9999) for i in range(len(pts) - 1)]
    return union(*segs)


def plane(n, d=0.0):
    """Half space n.p <= d is inside."""
    n = v3(n) / np.linalg.norm(n)
    return Shape(lambda p: p @ n - d, [-1e3] * 3, [1e3] * 3)


def union(*shapes, k=0.0):
    def f(p):
        d = shapes[0](p)
        for s in shapes[1:]:
            d = smin(d, s(p), k)
        return d

    lo = np.min([s.lo for s in shapes], axis=0) - k
    hi = np.max([s.hi for s in shapes], axis=0) + k
    return Shape(f, lo, hi)


def sym(shape):
    """Mirror across X = 0 (design on +X; both sides appear)."""

    def f(p):
        q = p.copy()
        q[:, 0] = np.abs(q[:, 0])
        return shape(q)

    lo, hi = shape.lo.copy(), shape.hi.copy()
    m = max(abs(lo[0]), abs(hi[0]))
    lo[0], hi[0] = -m, m
    return Shape(f, lo, hi)


def radial(shape, n, offset_deg=0.0):
    """Repeat a shape (designed around the +Z axis direction... any angle) n
    times around the Y axis by folding space (exact for convex-sector shapes)."""
    seg = 2 * math.pi / n
    off = math.radians(offset_deg)

    def f(p):
        a = np.arctan2(p[:, 0], p[:, 2]) - off
        a = np.mod(a + seg / 2, seg) - seg / 2 + off
        r = np.sqrt(p[:, 0] ** 2 + p[:, 2] ** 2)
        q = np.stack([r * np.sin(a), p[:, 1], r * np.cos(a)], -1)
        return shape(q)

    R_ = max(np.abs(shape.lo[[0, 2]]).max(), np.abs(shape.hi[[0, 2]]).max())
    R_ = math.hypot(R_, R_)
    return Shape(f, [-R_, shape.lo[1], -R_], [R_, shape.hi[1], R_])


def displace(shape, fn, amp):
    """Add a procedural displacement fn(p)->[-1,1] scaled by amp."""
    return Shape(lambda p: shape(p) + amp * fn(p), shape.lo - amp, shape.hi + amp)


# --------------------------------------------------------------------------
# model


class Group:
    def __init__(self, color, weight=1.0, min_tris=24, res=None):
        self.color = color
        self.ops = []  # (kind, shape, k)
        self.weight = weight
        self.min_tris = min_tris
        self.res = res
        self.icos = []  # explicit icospheres (center, radii, R, subdiv)

    def add(self, shape, k=0.0):
        self.ops.append(("add", shape, k))
        return self

    def sub(self, shape, k=0.0):
        self.ops.append(("sub", shape, k))
        return self

    def inter(self, shape, k=0.0):
        self.ops.append(("inter", shape, k))
        return self

    def sdf(self, p):
        d = None
        for kind, s, k in self.ops:
            v = s(p)
            if kind == "add":
                d = v if d is None else smin(d, v, k)
            elif kind == "sub":
                d = smax(d, -v, k)
            else:
                d = smax(d, v, k)
        return d

    def bounds(self):
        adds = [(s.lo - k, s.hi + k) for kind, s, k in self.ops if kind == "add"]
        lo = np.min([a for a, _ in adds], axis=0)
        hi = np.max([b for _, b in adds], axis=0)
        for kind, s, k in self.ops:
            if kind == "inter":
                lo = np.maximum(lo, s.lo - k)
                hi = np.minimum(hi, s.hi + k)
        return lo, hi


class Model:
    def __init__(self, name, budget, step=None, radius=None):
        self.name = name
        self.budget = budget
        self.step = step  # marching cubes cell size (studs); None: auto
        self.radius = radius  # hitbox radius the model was designed for
        self.groups: list[Group] = []
        self.balls = []  # (color, center, radii, R, subdiv)

    def group(self, color, **kw):
        g = Group(color, **kw)
        self.groups.append(g)
        return g

    def ball(self, color, c, r, R=None, subdiv=1):
        """A low-poly icosphere (r scalar or 3 radii) for tiny round details."""
        radii = v3([r, r, r] if np.isscalar(r) else r)
        self.balls.append((color, v3(c), radii, R, subdiv))

    def sym_ball(self, color, c, r, R=None, subdiv=1):
        c = v3(c)
        self.ball(color, c, r, R, subdiv)
        m = np.diag([-1.0, 1.0, 1.0])
        R2 = None if R is None else m @ np.asarray(R) @ m
        self.ball(color, c * [-1, 1, 1], r, R2, subdiv)

    # ---- meshing

    def _mesh_group(self, g: Group, step):
        lo, hi = g.bounds()
        ext = hi - lo
        st = g.res or min(step, ext.max() / 26.0)
        pad = 2.5 * st
        lo, hi = lo - pad, hi + pad
        n = np.ceil((hi - lo) / st).astype(int) + 1
        xs = [lo[i] + np.arange(n[i]) * st for i in range(3)]
        out = np.empty(n, dtype=np.float32)
        # evaluate slab by slab (memory)
        Y, Z = np.meshgrid(xs[1], xs[2], indexing="ij")
        yz = np.stack([Y.ravel(), Z.ravel()], -1)
        for i, x in enumerate(xs[0]):
            p = np.column_stack([np.full(len(yz), x), yz])
            out[i] = g.sdf(p).reshape(n[1], n[2])
        if out.min() >= 0 or out.max() <= 0:
            raise ValueError(f"{self.name}: a {g.color} group has no surface")
        verts, faces, _, _ = marching_cubes(out, 0.0, spacing=(st, st, st), allow_degenerate=False)
        verts = verts + lo
        # skimage winds faces so normals follow the gradient's descent; flip so
        # they point outward (increasing distance)
        faces = faces[:, ::-1]
        m = trimesh.Trimesh(verts, faces, process=True)
        m.merge_vertices()
        trimesh.smoothing.filter_taubin(m, lamb=0.5, nu=-0.53, iterations=6)
        return m

    def build(self, step=None):
        step = step or self.step
        lo = np.min([g.bounds()[0] for g in self.groups], axis=0)
        hi = np.max([g.bounds()[1] for g in self.groups], axis=0)
        if step is None:
            step = (hi - lo).max() / 150.0
        hi_meshes = [self._mesh_group(g, step) for g in self.groups]
        # explicit balls
        ball_meshes = []
        for color, c, radii, R, sd in self.balls:
            s = trimesh.creation.icosphere(subdivisions=sd, radius=1.0)
            v = s.vertices * radii
            if R is not None:
                v = v @ np.asarray(R).T
            ball_meshes.append((color, v + c, s.faces.copy()))
        ball_tris = sum(len(f) for _, _, f in ball_meshes)
        # triangle budget per group: area weighted, with minimums
        avail = self.budget - ball_tris
        areas = np.array([m.area * g.weight for m, g in zip(hi_meshes, self.groups)])
        mins = np.array([g.min_tris for g in self.groups], dtype=float)
        alloc = np.maximum(mins, avail * areas / areas.sum())
        # renormalise the non-minimum ones so the sum fits
        for _ in range(8):
            over = alloc.sum() - avail
            if over <= 0:
                break
            free = alloc > mins
            if not free.any():
                break
            alloc[free] = np.maximum(mins[free], alloc[free] - over * alloc[free] / alloc[free].sum())
        parts = []
        for m, g, t in zip(hi_meshes, self.groups, alloc):
            t = int(t)
            v, f = m.vertices, m.faces
            if len(f) > t:
                v, f = fast_simplification.simplify(v, f.astype(np.int32), target_count=t, agg=6)
            mm = trimesh.Trimesh(v, f, process=True)
            mm.remove_unreferenced_vertices()
            parts.append((g.color, mm.vertices.copy(), mm.faces.copy(), mm.vertex_normals.copy()))
        for color, v, f in ball_meshes:
            mm = trimesh.Trimesh(v, f, process=False)
            parts.append((color, v, f, mm.vertex_normals.copy()))
        return Built(self, parts)


class Built:
    """A finished model: merged arrays plus palette."""

    SW = 8  # swatch size in texels
    COLS = 8  # swatches per row (64x64 texture -> 64 colours max)

    def __init__(self, model: Model, parts):
        self.name = model.name
        self.model = model
        palette = []
        V, N, F, C = [], [], [], []
        off = 0
        for color, v, f, n in parts:
            if color not in palette:
                palette.append(color)
            ci = palette.index(color)
            V.append(v)
            N.append(n)
            F.append(f + off)
            C.append(np.full(len(v), ci))
            off += len(v)
        V = np.concatenate(V)
        N = np.concatenate(N)
        F = np.concatenate(F)
        C = np.concatenate(C)
        # place: centre X/Z of the bounding box, feet at Y=0
        lo, hi = V.min(0), V.max(0)
        shift = np.array([-(lo[0] + hi[0]) / 2, -lo[1], -(lo[2] + hi[2]) / 2])
        V = V + shift
        self.shift = shift
        N = N / np.maximum(_len(N)[:, None], 1e-9)
        self.V, self.N, self.F, self.C = V, N, F, C
        self.palette = palette
        if len(palette) > self.COLS * self.COLS:
            raise ValueError(f"{self.name}: too many colours ({len(palette)})")

    @property
    def tris(self):
        return len(self.F)

    def size(self):
        return self.V.max(0) - self.V.min(0)

    def texture_png(self):
        n = self.COLS * self.SW
        img = Image.new("RGB", (n, n), (255, 0, 255))
        px = img.load()
        for i, c in enumerate(self.palette):
            x0, y0 = (i % self.COLS) * self.SW, (i // self.COLS) * self.SW
            for y in range(self.SW):
                for x in range(self.SW):
                    px[x0 + x, y0 + y] = c
        buf = io.BytesIO()
        img.save(buf, format="PNG", optimize=True)
        return buf.getvalue()

    def uvs(self):
        n = self.COLS * self.SW
        u = ((self.C % self.COLS) * self.SW + self.SW / 2) / n
        v = ((self.C // self.COLS) * self.SW + self.SW / 2) / n
        return np.stack([u, v], -1)

    def vertex_rgb(self):
        pal = np.array(self.palette, dtype=np.float64) / 255.0
        return pal[self.C]

    def write_glb(self, path, color_mode="texture", extras=None):
        """color_mode: "texture" (baseColorTexture palette, default),
        "vertex" (COLOR_0 only, white material) or "both" (texture + COLOR_0;
        note glTF multiplies them)."""
        V = self.V.astype(np.float32)
        N = self.N.astype(np.float32)
        UV = self.uvs().astype(np.float32)
        F = self.F.astype(np.uint16 if len(V) < 65536 else np.uint32)
        blobs = []
        views = []
        accessors = []

        def add_view(data: bytes, target=None):
            off = sum(len(b) for b in blobs)
            pad = (-len(data)) % 4
            blobs.append(data + b"\0" * pad)
            view = {"buffer": 0, "byteOffset": off, "byteLength": len(data)}
            if target:
                view["target"] = target
            views.append(view)
            return len(views) - 1

        def add_acc(arr, ctype, typ, target, minmax=False, normalized=False):
            vi = add_view(arr.tobytes(), target)
            acc = {"bufferView": vi, "componentType": ctype, "count": int(len(arr)), "type": typ}
            if normalized:
                acc["normalized"] = True
            if minmax:
                acc["min"] = [float(x) for x in arr.min(0)]
                acc["max"] = [float(x) for x in arr.max(0)]
            accessors.append(acc)
            return len(accessors) - 1

        attrs = {
            "POSITION": add_acc(V, 5126, "VEC3", 34962, minmax=True),
            "NORMAL": add_acc(N, 5126, "VEC3", 34962),
        }
        use_tex = color_mode in ("texture", "both")
        if use_tex:
            attrs["TEXCOORD_0"] = add_acc(UV, 5126, "VEC2", 34962)
        if color_mode in ("vertex", "both"):
            col = np.concatenate([self.vertex_rgb() ** 2.2, np.ones((len(V), 1))], 1)  # glTF COLOR_0 is linear
            col = np.round(col * 255).astype(np.uint8)
            attrs["COLOR_0"] = add_acc(col, 5121, "VEC4", 34962, normalized=True)
        idx = add_acc(F.reshape(-1), 5125 if F.dtype == np.uint32 else 5123, "SCALAR", 34963)
        pbr = {"metallicFactor": 0.0, "roughnessFactor": 0.6, "baseColorFactor": [1, 1, 1, 1]}
        gltf = {
            "asset": {"version": "2.0", "generator": "Trunkfall meshkit (scripts/make-meshes.py)"},
            "scene": 0,
            "scenes": [{"nodes": [0]}],
            "nodes": [{"mesh": 0, "name": self.name, "extras": extras or {}}],
            "meshes": [
                {"name": self.name, "primitives": [{"attributes": attrs, "indices": idx, "material": 0, "mode": 4}]}
            ],
            "materials": [{"name": self.name + "_mat", "pbrMetallicRoughness": pbr, "doubleSided": False}],
        }
        if use_tex:
            iv = add_view(self.texture_png())
            gltf["images"] = [{"bufferView": iv, "mimeType": "image/png", "name": self.name + "_palette"}]
            gltf["samplers"] = [{"magFilter": 9728, "minFilter": 9729, "wrapS": 33071, "wrapT": 33071}]
            gltf["textures"] = [{"source": 0, "sampler": 0}]
            pbr["baseColorTexture"] = {"index": 0}
        bin_ = b"".join(blobs)
        gltf["buffers"] = [{"byteLength": len(bin_)}]
        gltf["bufferViews"] = views
        gltf["accessors"] = accessors
        js = json.dumps(gltf, separators=(",", ":"), sort_keys=True).encode()
        js += b" " * ((-len(js)) % 4)
        total = 12 + 8 + len(js) + 8 + len(bin_)
        with open(path, "wb") as fh:
            fh.write(struct.pack("<4sII", b"glTF", 2, total))
            fh.write(struct.pack("<I4s", len(js), b"JSON"))
            fh.write(js)
            fh.write(struct.pack("<I4s", len(bin_), b"BIN\0"))
            fh.write(bin_)
        return total


# --------------------------------------------------------------------------
# tiny software renderer for preview sheets (no GPU needed)


def render(built: Built, size=360, yaw=-35.0, pitch=18.0, bg=(238, 240, 245), ss=2):
    """Return a PIL image of the model, three-quarter front view, Lambert +
    ambient + rim light, smooth normals, z-buffered."""
    W = size * ss
    V, N, F = built.V, built.N, built.F
    col = built.vertex_rgb()
    ctr = (V.max(0) + V.min(0)) / 2
    # camera: rotate world so we look from the front (-Z side) slightly left/above
    Ry = rot(0, yaw, 0)
    Rx = rot(pitch, 0, 0)
    M = Rx @ Ry
    P = (V - ctr) @ M.T
    Nn = N @ M.T
    # the model faces -Z; camera sits at -Z looking +Z: screen x = -? keep handedness:
    sx = -P[:, 0]  # mirror so the model's right appears on screen left (we face it)
    sy = P[:, 1]
    depth = P[:, 2]  # smaller = closer (camera at -Z)
    ext = max(sx.max() - sx.min(), sy.max() - sy.min()) * 1.12
    scale = W / ext
    X = (sx - (sx.max() + sx.min()) / 2) * scale + W / 2
    Y = W / 2 - (sy - (sy.max() + sy.min()) / 2) * scale
    light = v3(0.45, 0.75, -0.5)
    light /= np.linalg.norm(light)
    view = v3(0, 0, -1.0)
    nl = np.clip(Nn @ light, 0, 1)
    # Nn is in camera space with the sx flip applied only to positions; flip x
    Nc = Nn.copy()
    nl = np.clip(Nc @ light, 0, 1)
    rim = np.clip(1 - np.abs(Nc @ view), 0, 1) ** 3
    shade = 0.42 + 0.62 * nl
    vc = np.clip(col * shade[:, None] + 0.18 * rim[:, None], 0, 1)
    img = np.empty((W, W, 3), dtype=np.float64)
    img[:] = np.array(bg) / 255.0
    # soft ground shadow ellipse
    zbuf = np.full((W, W), np.inf)
    tri = F
    order = np.argsort(-depth[tri].mean(1))
    for t in order:
        i0, i1, i2 = tri[t]
        x0, y0, x1, y1, x2, y2 = X[i0], Y[i0], X[i1], Y[i1], X[i2], Y[i2]
        minx, maxx = int(max(0, math.floor(min(x0, x1, x2)))), int(min(W - 1, math.ceil(max(x0, x1, x2))))
        miny, maxy = int(max(0, math.floor(min(y0, y1, y2)))), int(min(W - 1, math.ceil(max(y0, y1, y2))))
        if minx > maxx or miny > maxy:
            continue
        den = (y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2)
        if abs(den) < 1e-12:
            continue
        xs = np.arange(minx, maxx + 1) + 0.5
        ys = np.arange(miny, maxy + 1) + 0.5
        gx, gy = np.meshgrid(xs, ys)
        w0 = ((y1 - y2) * (gx - x2) + (x2 - x1) * (gy - y2)) / den
        w1 = ((y2 - y0) * (gx - x2) + (x0 - x2) * (gy - y2)) / den
        w2 = 1 - w0 - w1
        inside = (w0 >= -1e-6) & (w1 >= -1e-6) & (w2 >= -1e-6)
        if not inside.any():
            continue
        z = w0 * depth[i0] + w1 * depth[i1] + w2 * depth[i2]
        zb = zbuf[miny : maxy + 1, minx : maxx + 1]
        m = inside & (z < zb)
        if not m.any():
            continue
        zb[m] = z[m]
        c = w0[..., None] * vc[i0] + w1[..., None] * vc[i1] + w2[..., None] * vc[i2]
        sub = img[miny : maxy + 1, minx : maxx + 1]
        sub[m] = c[m]
    out = Image.fromarray(np.clip(img * 255, 0, 255).astype(np.uint8))
    if ss > 1:
        out = out.resize((size, size), Image.LANCZOS)
    return out
