"""meshkit: a tiny signed-distance modeller for Trunkfall's "chunky toy" meshes.

Used by scripts/make-meshes.py (see that file and assets/models/PLAN.md).

A Model is a list of colour groups. Each group is one solid colour built from
SDF primitives combined with smooth union / subtraction / intersection, meshed
with marching cubes, lightly Taubin-smoothed and decimated to its share of the
model's triangle budget. Groups of different colours simply interpenetrate
(like painted toy parts), so colour borders are crisp and every vertex carries
exactly one palette colour. Small round details (eye glints) can be added as
low-poly icospheres.

iter7: a model can declare animation pieces (Model.piece); the groups are cut
along the piece regions (closed caps, a small inset overlap at the joints) and
write_glb emits one node + mesh per piece, named after it (the Roblox importer
makes one MeshPart per node). Without pieces everything is "body".

Output (write_glb): one mesh per piece, one material whose baseColorTexture is a tiny
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
    if np.allclose(a, b):
        return sphere(a, max(ra, rb))
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
    def __init__(self, color, weight=1.0, min_tris=24, res=None, flat=False, max_tris=None, piece=None):
        self.color = color
        self.piece = piece  # iter7: whole group goes to this piece (else: cut by the piece regions)
        self.max_tris = max_tris
        self.flat = flat  # faceted (per-face normals), e.g. origami paper
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
        self.raws = []  # (color, verts, faces, piece): explicit flat-shaded meshes
        self.pieces = []  # iter7: animation pieces, in classification order (see piece())

    def piece(self, name, region=None, joint=None, parent=None, bone=None, colors=None, cond=None, anim=None, neon=False, margin=None, rot=None):
        """Declare an animation piece (iter7: animation-ready meshes).

        Each piece becomes its own glTF node/mesh named `name` (the importer makes
        one MeshPart per node). Geometry is assigned in declaration order: a group
        with an explicit `piece` goes there whole; every other group is cut by the
        piece `region`s (SDF shapes; first match wins; `colors` limits a region to
        groups/balls of those colours), and what no region claims is "body". A
        piece overlaps its neighbours by `margin` (slightly inset) so joints show
        no cracks when it rotates; declare children (ears, legs) before parents
        (head). `joint` is the bone pivot (model space, before centring); `rot`
        (Euler degrees) orients it (spin axes). `bone` defaults to the name;
        `parent` is the parent bone; `cond` ("elite") hides it unless the
        condition holds; `anim` is a Spec anim dict (kind, amp, freq, phase)
        played about the joint; `neon` makes it a flat Neon accent."""
        self.pieces.append(
            dict(name=name, region=region, joint=None if joint is None else v3(joint), parent=parent, bone=bone,
                 colors=None if colors is None else set(colors), cond=cond, anim=anim, neon=neon, margin=margin, rot=rot)
        )
        return self

    def _classify(self, color, point):
        for pc in self.pieces:
            if pc["region"] is None or (pc["colors"] is not None and color not in pc["colors"]):
                continue
            if float(pc["region"](np.asarray(point, dtype=np.float64)[None, :])[0]) < 0:
                return pc["name"]
        return "body"

    def prism(self, color, a, b, c, thickness, piece=None):
        """A thin flat-shaded triangular slab (crystal membranes, paper)."""
        a, b, c = v3(a), v3(b), v3(c)
        n = np.cross(b - a, c - a)
        n = n / np.linalg.norm(n) * thickness / 2
        V = np.array([a + n, b + n, c + n, a - n, b - n, c - n])
        F = np.array([[0, 1, 2], [3, 5, 4], [0, 3, 4], [0, 4, 1], [1, 4, 5], [1, 5, 2], [2, 5, 3], [2, 3, 0]])
        # orient outward: the first face must point along +n
        if np.dot(np.cross(V[1] - V[0], V[2] - V[0]), n) < 0:
            F = F[:, ::-1]
        self.raws.append((color, V, F, piece))

    def group(self, color, **kw):
        g = Group(color, **kw)
        self.groups.append(g)
        return g

    def ball(self, color, c, r, R=None, subdiv=1, piece=None):
        """A low-poly icosphere (r scalar or 3 radii) for tiny round details."""
        radii = v3([r, r, r] if np.isscalar(r) else r)
        self.balls.append((color, v3(c), radii, R, subdiv, piece))

    def sym_ball(self, color, c, r, R=None, subdiv=1, piece=None):
        c = v3(c)
        self.ball(color, c, r, R, subdiv, piece)
        m = np.diag([-1.0, 1.0, 1.0])
        R2 = None if R is None else m @ np.asarray(R) @ m
        self.ball(color, c * [-1, 1, 1], r, R2, subdiv, piece)

    # ---- meshing

    def _grid(self, g: Group, step):
        lo, hi = g.bounds()
        ext = hi - lo
        st = g.res or min(step, ext.max() / 26.0)
        pad = 2.5 * st
        lo, hi = lo - pad, hi + pad
        n = np.ceil((hi - lo) / st).astype(int) + 1
        xs = [lo[i] + np.arange(n[i]) * st for i in range(3)]
        return lo, st, n, xs

    @staticmethod
    def _eval(fn, n, xs):
        out = np.empty(n, dtype=np.float32)
        # evaluate slab by slab (memory)
        Y, Z = np.meshgrid(xs[1], xs[2], indexing="ij")
        yz = np.stack([Y.ravel(), Z.ravel()], -1)
        for i, x in enumerate(xs[0]):
            p = np.column_stack([np.full(len(yz), x), yz])
            out[i] = fn(p).reshape(n[1], n[2])
        return out

    @staticmethod
    def _mc(field, lo, st):
        if field.min() >= 0 or field.max() <= 0:
            return None
        verts, faces, _, _ = marching_cubes(field, 0.0, spacing=(st, st, st), allow_degenerate=False)
        verts = verts + lo
        # skimage winds faces so normals follow the gradient's descent; flip so
        # they point outward (increasing distance)
        faces = faces[:, ::-1]
        m = trimesh.Trimesh(verts, faces, process=True)
        m.merge_vertices()
        if len(m.faces) < 4:
            return None
        trimesh.smoothing.filter_taubin(m, lamb=0.5, nu=-0.53, iterations=6)
        return m

    def _mesh_group(self, g: Group, step):
        """-> [(piece, trimesh)]: the group's surface, cut into its pieces."""
        lo, st, n, xs = self._grid(g, step)
        gs = self._eval(g.sdf, n, xs)
        if gs.min() >= 0 or gs.max() <= 0:
            raise ValueError(f"{self.name}: a {g.color} group has no surface")
        elig = [pc for pc in self.pieces if pc["region"] is not None and (pc["colors"] is None or g.color in pc["colors"])]
        if g.piece is not None or not elig:
            return [(g.piece or "body", self._mc(gs, lo, st))]
        R = [self._eval(pc["region"], n, xs) for pc in elig]
        out = []
        prior = None  # min of the earlier regions (> 0: outside all of them)
        for pc, r in zip(elig, R):
            margin = pc["margin"] if pc["margin"] is not None else 2.0 * st
            # inside the region grown by `margin`, outside every earlier region;
            # in the overlap band the surface is inset a little so the
            # neighbour's surface wins (no z-fighting, no crack when posed)
            f = np.maximum(gs + 0.35 * st * np.clip(r / max(margin, 1e-6), 0.0, 1.0), r - margin)
            if prior is not None:
                f = np.maximum(f, -prior)
            out.append((pc["name"], self._mc(f, lo, st)))
            prior = r if prior is None else np.minimum(prior, r)
        out.append(("body", self._mc(np.maximum(gs, -prior), lo, st)))
        return [(name, m) for name, m in out if m is not None]

    def build(self, step=None):
        step = step or self.step
        lo = np.min([g.bounds()[0] for g in self.groups], axis=0)
        hi = np.max([g.bounds()[1] for g in self.groups], axis=0)
        if step is None:
            step = (hi - lo).max() / 150.0
        frags = []  # (group, piece, hi-res mesh, min share)
        for g in self.groups:
            fr = self._mesh_group(g, step)
            total = sum(m.area for _, m in fr) or 1.0
            for piece, m in fr:
                frags.append((g, piece, m, m.area / total))
        # explicit balls
        ball_meshes = []
        for color, c, radii, R, sd, piece in self.balls:
            s = trimesh.creation.icosphere(subdivisions=sd, radius=1.0)
            v = s.vertices * radii
            if R is not None:
                v = v @ np.asarray(R).T
            ball_meshes.append((color, v + c, s.faces.copy(), None, piece or self._classify(color, c)))
        for color, v, f, piece in self.raws:
            mm = trimesh.Trimesh(v, f, process=False)
            fv = mm.vertices[mm.faces].reshape(-1, 3)
            ball_meshes.append(
                (color, fv, np.arange(len(fv)).reshape(-1, 3), np.repeat(mm.face_normals, 3, axis=0), piece or self._classify(color, v.mean(0)))
            )
        ball_tris = sum(len(b[2]) for b in ball_meshes)
        # triangle budget per fragment: area weighted, with minimums (a group's
        # minimum is shared by its pieces by area)
        avail = self.budget - ball_tris
        areas = np.array([m.area * g.weight for g, _, m, _ in frags])
        mins = np.array([max(8.0, g.min_tris * share) for g, _, _, share in frags], dtype=float)
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
        alloc = np.minimum(alloc, [len(m.faces) for _, _, m, _ in frags])
        alloc = np.minimum(alloc, [(g.max_tris or 1e9) * share for g, _, _, share in frags])
        for _ in range(8):
            parts = []
            for (g, piece, m, _), t in zip(frags, alloc):
                t = max(8, int(t))
                v, f = m.vertices, m.faces
                if len(f) > t:
                    v, f = fast_simplification.simplify(v, f.astype(np.int32), target_count=t, agg=6)
                    # iter8: flat-sided shapes can stall the decimator; push harder
                    for agg in (8, 10, 12):
                        if len(f) <= t * 1.05:
                            break
                        v, f = fast_simplification.simplify(v, f.astype(np.int32), target_count=t, agg=agg)
                mm = trimesh.Trimesh(v, f, process=True)
                mm.remove_unreferenced_vertices()
                if len(mm.faces) == 0:
                    continue
                if g.flat:
                    fv = mm.vertices[mm.faces].reshape(-1, 3)
                    fn = np.repeat(mm.face_normals, 3, axis=0)
                    parts.append((g.color, fv, np.arange(len(fv)).reshape(-1, 3), fn, piece))
                else:
                    parts.append((g.color, mm.vertices.copy(), mm.faces.copy(), mm.vertex_normals.copy(), piece))
            total = sum(len(p[2]) for p in parts) + ball_tris
            if total <= self.budget:
                break
            alloc = alloc * (self.budget - ball_tris) / (total - ball_tris) * 0.97
        for color, v, f, n, piece in ball_meshes:
            if n is None:
                n = trimesh.Trimesh(v, f, process=False).vertex_normals.copy()
            parts.append((color, v, f, n, piece))
        return Built(self, parts)


class Built:
    """A finished model: merged arrays plus palette."""

    SW = 8  # swatch size in texels
    COLS = 8  # swatches per row (64x64 texture -> 64 colours max)

    def __init__(self, model: Model, parts):
        self.name = model.name
        self.model = model
        palette = []
        V, N, F, C, P = [], [], [], [], []
        # piece order: body first, then the declared pieces
        names = ["body"] + [pc["name"] for pc in model.pieces if pc["name"] != "body"]
        for *_, piece in parts:
            if piece not in names:
                names.append(piece)
        off = 0
        for color, v, f, n, piece in parts:
            if color not in palette:
                palette.append(color)
            ci = palette.index(color)
            V.append(v)
            N.append(n)
            F.append(f + off)
            C.append(np.full(len(v), ci))
            P.append(np.full(len(v), names.index(piece)))
            off += len(v)
        V = np.concatenate(V)
        N = np.concatenate(N)
        F = np.concatenate(F)
        C = np.concatenate(C)
        P = np.concatenate(P)
        # place: centre X/Z of the bounding box, feet at Y=0
        lo, hi = V.min(0), V.max(0)
        shift = np.array([-(lo[0] + hi[0]) / 2, -lo[1], -(lo[2] + hi[2]) / 2])
        V = V + shift
        self.shift = shift
        N = N / np.maximum(_len(N)[:, None], 1e-9)
        self.V, self.N, self.F, self.C, self.P = V, N, F, C, P
        self.palette = palette
        if len(palette) > self.COLS * self.COLS:
            raise ValueError(f"{self.name}: too many colours ({len(palette)})")
        # pieces that ended up with geometry
        fp = P[F[:, 0]]
        decl = {pc["name"]: pc for pc in model.pieces}
        self.pieces = []
        for i, name in enumerate(names):
            fm = fp == i
            if not fm.any():
                continue
            vi = np.unique(F[fm])
            pv = V[vi]
            plo, phi = pv.min(0), pv.max(0)
            counts = np.bincount(C[F[fm][:, 0]], minlength=len(palette))
            pc = decl.get(name, {})
            joint = pc.get("joint")
            joint = (plo + phi) / 2 if joint is None else joint + shift
            self.pieces.append(
                dict(
                    name=name,
                    index=i,
                    center=(plo + phi) / 2,
                    size=phi - plo,
                    tris=int(fm.sum()),
                    color=palette[int(counts.argmax())],
                    joint=joint,
                    bone=pc.get("bone"),
                    parent=pc.get("parent"),
                    cond=pc.get("cond"),
                    anim=pc.get("anim"),
                    neon=bool(pc.get("neon")),
                    rot=pc.get("rot"),
                )
            )

    def piece_info(self):
        """JSON-ready piece table (meshes.json / Visuals/MeshData.luau)."""
        out = []
        for pc in self.pieces:
            e = {
                "name": pc["name"],
                "center": [round(float(x), 4) for x in pc["center"]],
                "size": [round(float(x), 4) for x in pc["size"]],
                "joint": [round(float(x), 4) for x in pc["joint"]],
                "tris": pc["tris"],
                "color": list(pc["color"]),
            }
            for k in ("bone", "parent", "cond", "anim", "rot"):
                if pc.get(k) is not None:
                    e[k] = pc[k]
            if pc["neon"]:
                e["neon"] = True
            out.append(e)
        return out

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

        use_tex = color_mode in ("texture", "both")
        col_all = None
        if color_mode in ("vertex", "both"):
            col_all = np.concatenate([self.vertex_rgb() ** 2.2, np.ones((len(V), 1))], 1)  # glTF COLOR_0 is linear
            col_all = np.round(col_all * 255).astype(np.uint8)
        fp = self.P[self.F[:, 0]]
        nodes, meshes = [], []
        # one node + mesh per animation piece (the importer makes a MeshPart per
        # node, named after it); all share the palette material
        for pc in self.pieces:
            fsel = self.F[fp == pc["index"]]
            vi, inv = np.unique(fsel.reshape(-1), return_inverse=True)
            Fp = inv.reshape(-1, 3).astype(np.uint16 if len(vi) < 65536 else np.uint32)
            attrs = {
                "POSITION": add_acc(V[vi], 5126, "VEC3", 34962, minmax=True),
                "NORMAL": add_acc(N[vi], 5126, "VEC3", 34962),
            }
            if use_tex:
                attrs["TEXCOORD_0"] = add_acc(UV[vi], 5126, "VEC2", 34962)
            if col_all is not None:
                attrs["COLOR_0"] = add_acc(col_all[vi], 5121, "VEC4", 34962, normalized=True)
            idx = add_acc(Fp.reshape(-1), 5125 if Fp.dtype == np.uint32 else 5123, "SCALAR", 34963)
            meshes.append({"name": pc["name"], "primitives": [{"attributes": attrs, "indices": idx, "material": 0, "mode": 4}]})
            nodes.append({"mesh": len(meshes) - 1, "name": pc["name"], "extras": dict(extras or {}, piece=pc["name"])})
        pbr = {"metallicFactor": 0.0, "roughnessFactor": 0.6, "baseColorFactor": [1, 1, 1, 1]}
        gltf = {
            "asset": {"version": "2.0", "generator": "Trunkfall meshkit (scripts/make-meshes.py)"},
            "scene": 0,
            "scenes": [{"name": self.name, "nodes": list(range(len(nodes)))}],
            "nodes": nodes,
            "meshes": meshes,
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


def render(built: Built, size=360, yaw=-28.0, pitch=20.0, bg=(238, 240, 245), ss=2, explode=0.0):
    """Return a PIL image of the model, three-quarter front view, Lambert +
    ambient + rim light, smooth normals, z-buffered. `explode` > 0 pushes the
    animation pieces apart (from their joints, away from the body) to check the
    piece split."""
    W = size * ss
    V, N, F = built.V, built.N, built.F
    if explode > 0:
        V = V.copy()
        body = next((pc for pc in built.pieces if pc["name"] == "body"), None)
        bc = body["center"] if body else V.mean(0)
        for pc in built.pieces:
            if pc["name"] == "body":
                continue
            d = pc["center"] - bc
            V[built.P == pc["index"]] += d * explode
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
