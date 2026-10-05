"""Author race identity parts (dark, undead) in Blender and export bind-matched runtime parts.

blender --background --python-exit-code 1 --python tools/model_refinement/build_dark_parts.py -- \
    --unit dark_dragon --refs <delivery>/source --out <delivery>/source/dark_dragon/parts [--render]

Inputs come from export_unit_reference.gd: rig.json and reference_<k>.glb (the
real body, upright, Godot Y-up, +Z front). Parts are authored once in that
upright space below (one DESIGNS entry per unit, values in model units).

Outputs:
  <unit>_parts_source.blend   editable: reference body + named parts per logical bone
  <unit>_parts.glb            runtime: one mesh per (rig, bone), vertices local to that
                              bone's rest in that rig; glTF extras {bone, bind}
  parts-manifest.json         rigs, offsets, per-bone vertex/triangle counts
  render_*.png                quick Workbench views (with --render)

Vertex colour RGB is the albedo, alpha the glow amount (dark_parts.gdshader).
The original body, rig and animations are references only and never exported.
"""
import argparse
import json
import math
import struct
import sys
from pathlib import Path

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

C = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))  # Godot -> Blender
C_INV = C.inverted()

# Linear RGB + glow (alpha). One race palette (2026-10-04 review: colours unified,
# no pink): every glowing part uses the same violet. Red stays ~0.4x blue because
# the lit albedo adds on top of the glow and the old (0.52, 0.2, 1.0) clipped to
# magenta-pink in battle.
PALETTE = {
    "void": (0.030, 0.020, 0.048, 0.0),
    "iron": (0.085, 0.070, 0.120, 0.0),
    "horn": (0.060, 0.040, 0.085, 0.0),
    "bone": (0.360, 0.290, 0.470, 0.0),
    "membrane": (0.100, 0.040, 0.210, 0.12),
    "violet": (0.300, 0.140, 0.800, 1.0),
    "violet_dim": (0.160, 0.070, 0.400, 0.45),
    "steel": (0.300, 0.270, 0.380, 0.0),
}

# Undead: one toxic green (2026-10-04 review: unified to the small/poison/parasite green).
# Green ~4x red so lit glow never clips to yellow.
TOXIC = {
    "void": (0.012, 0.022, 0.010, 0.0),
    "olive": (0.100, 0.120, 0.050, 0.0),
    "bone": (0.540, 0.560, 0.430, 0.0),
    "glass": (0.060, 0.300, 0.040, 0.55),
    "toxic": (0.200, 0.800, 0.060, 1.0),
    "toxic_dim": (0.080, 0.360, 0.030, 0.5),
}

LOGICAL = {  # logical bone -> per rig family
    "head": {"cc": "CC_Base_Head", "mixamo": "mixamorig_Head", "bare": "Head"},
    "chest": {"cc": "CC_Base_Spine02", "mixamo": "mixamorig_Spine2", "bare": "Spine02"},
    "pelvis": {"cc": "CC_Base_Pelvis", "mixamo": "mixamorig_Hips", "bare": "Pelvis"},
}


# ---------------------------------------------------------------- geometry
def lerp(a, b, t):
    return a + (b - a) * t


def catmull(points, samples):
    pts = [Vector(p) for p in points]
    if len(pts) == 2:
        return [pts[0].lerp(pts[1], i / (samples - 1)) for i in range(samples)]
    ext = [pts[0] * 2 - pts[1]] + pts + [pts[-1] * 2 - pts[-2]]
    out = []
    segs = len(pts) - 1
    for i in range(samples):
        u = i / (samples - 1) * segs
        k = min(int(u), segs - 1)
        t = u - k
        p0, p1, p2, p3 = ext[k], ext[k + 1], ext[k + 2], ext[k + 3]
        out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t))
    return out


class Builder:
    def __init__(self):
        self.parts = []  # (object, logical bone)

    def _object(self, name, verts, faces, colors, bone, smooth=True):
        mesh = bpy.data.meshes.new(name)
        mesh.from_pydata([tuple((C @ Vector((*v, 1.0))).xyz) for v in verts], [], faces)
        mesh.update()
        obj = bpy.data.objects.new(name, mesh)
        bpy.context.scene.collection.objects.link(obj)
        bm = bmesh.new()
        bm.from_mesh(mesh)
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        bm.to_mesh(mesh)
        bm.free()
        for poly in mesh.polygons:
            poly.use_smooth = smooth
        attr = mesh.color_attributes.new(name="Color", type="FLOAT_COLOR", domain="POINT")
        for i, c in enumerate(colors):
            attr.data[i].color = c
        mesh.color_attributes.active_color = attr
        obj["logical_bone"] = bone
        self.parts.append((obj, bone))
        return obj

    def tube(self, name, bone, points, radii, colors, sides=8, samples=16, flat=1.0):
        """Tapered sweep. radii/colors: list of (t, value) keys; flat squashes the cross-section."""
        path = catmull(points, samples)
        def key(keys, t):
            for (t0, v0), (t1, v1) in zip(keys, keys[1:]):
                if t0 <= t <= t1:
                    f = (t - t0) / max(t1 - t0, 1e-6)
                    return tuple(lerp(a, b, f) for a, b in zip(v0, v1)) if isinstance(v0, tuple) else lerp(v0, v1, f)
            return keys[-1][1]
        tangents = [(path[min(i + 1, samples - 1)] - path[max(i - 1, 0)]).normalized() for i in range(samples)]
        ref = Vector((0, 0, 1)) if abs(tangents[0].z) < 0.9 else Vector((1, 0, 0))
        normal = tangents[0].cross(ref).normalized()
        verts, cols, faces = [], [], []
        for i in range(samples):
            if i:
                axis = tangents[i - 1].cross(tangents[i])
                if axis.length > 1e-6:
                    normal = (Matrix.Rotation(tangents[i - 1].angle(tangents[i]), 3, axis.normalized()) @ normal).normalized()
            binormal = tangents[i].cross(normal).normalized()
            t = i / (samples - 1)
            r = key(radii, t)
            c = key(colors, t)
            for j in range(sides):
                a = 2 * math.pi * j / sides
                verts.append(tuple(path[i] + normal * math.cos(a) * r + binormal * math.sin(a) * r * flat))
                cols.append(c)
        for i in range(samples - 1):
            for j in range(sides):
                faces.append((i * sides + j, i * sides + (j + 1) % sides, (i + 1) * sides + (j + 1) % sides, (i + 1) * sides + j))
        verts.append(tuple(path[0])); cols.append(key(colors, 0.0))
        faces += [(len(verts) - 1, (j + 1) % sides, j) for j in range(sides)]
        if key(radii, 1.0) > 1e-4:
            verts.append(tuple(path[-1] + tangents[-1] * key(radii, 1.0))); cols.append(key(colors, 1.0))
            base = (samples - 1) * sides
            faces += [(len(verts) - 1, base + j, base + (j + 1) % sides) for j in range(sides)]
        return self._object(name, verts, faces, cols, bone)

    def plate(self, name, bone, outline, center, u, v, w, depth, color, edge=None, bevel=0.0):
        """Extruded 2D outline (in u/v) with optional glowing rim colour on the side walls."""
        c, u, v, w = Vector(center), Vector(u).normalized(), Vector(v).normalized(), Vector(w).normalized()
        n = len(outline)
        verts, cols = [], []
        for z in (-depth / 2, depth / 2):
            for x, y in outline:
                verts.append(tuple(c + u * x + v * y + w * z))
                cols.append(color)
        faces = [tuple(reversed(range(n))), tuple(range(n, 2 * n))]
        faces += [(i, (i + 1) % n, (i + 1) % n + n, i + n) for i in range(n)]
        obj = self._object(name, verts, faces, cols, bone, smooth=False)
        if edge is not None:
            # Split the side walls (every face after the two caps) so they can carry
            # the edge colour. Selecting them by vertex count painted 4-point caps too.
            bm = bmesh.new(); bm.from_mesh(obj.data)
            bm.faces.ensure_lookup_table()
            bmesh.ops.split(bm, geom=[bm.faces[i] for i in range(2, len(bm.faces))])
            bm.to_mesh(obj.data); bm.free()
            attr = obj.data.color_attributes["Color"]
            for poly in obj.data.polygons[2:]:
                for vi in poly.vertices:
                    attr.data[vi].color = edge
        if bevel:
            mod = obj.modifiers.new("bevel", "BEVEL"); mod.width = bevel; mod.segments = 2
            bpy.context.view_layer.objects.active = obj
            bpy.ops.object.modifier_apply(modifier=mod.name)
        return obj

    def torus(self, name, bone, center, normal, radius, thickness, color, seg=12, sides=6, stretch=1.0, tangent=None):
        c, n = Vector(center), Vector(normal).normalized()
        a = Vector(tangent).normalized() if tangent else (n.cross(Vector((0, 1, 0))) if abs(n.y) < 0.9 else n.cross(Vector((1, 0, 0)))).normalized()
        b = n.cross(a).normalized()
        verts, faces = [], []
        for i in range(seg):
            th = 2 * math.pi * i / seg
            ring_c = c + a * math.cos(th) * radius * stretch + b * math.sin(th) * radius
            radial = (a * math.cos(th) * stretch + b * math.sin(th)).normalized()
            for j in range(sides):
                ph = 2 * math.pi * j / sides
                verts.append(tuple(ring_c + radial * math.cos(ph) * thickness + n * math.sin(ph) * thickness))
        for i in range(seg):
            for j in range(sides):
                faces.append((i * sides + j, i * sides + (j + 1) % sides, ((i + 1) % seg) * sides + (j + 1) % sides, ((i + 1) % seg) * sides + j))
        return self._object(name, verts, faces, [color] * len(verts), bone)

    def membrane(self, name, bone, root, spars, color_root, color_edge, sag=0.18, rows=6):
        """Wing skin between consecutive spar polylines (already sampled), edge scalloped toward the root."""
        verts, cols, faces = [], [], []
        root = Vector(root)
        for k in range(len(spars) - 1):
            a, b = [Vector(p) for p in spars[k]], [Vector(p) for p in spars[k + 1]]
            m = min(len(a), len(b))
            base = len(verts)
            for i in range(m):
                t = i / (m - 1)
                for r in range(rows + 1):
                    s = r / rows
                    p = a[i].lerp(b[i], s)
                    # Scallop: pull the free edge segment between spar tips toward the root.
                    if i == m - 1:
                        p = p.lerp(root, sag * math.sin(math.pi * s))
                    verts.append(tuple(p))
                    glow = color_root if t < 0.7 else tuple(lerp(x, y, (t - 0.7) / 0.3) for x, y in zip(color_root, color_edge))
                    cols.append(glow)
            for i in range(m - 1):
                for r in range(rows):
                    q = base + i * (rows + 1) + r
                    faces.append((q, q + 1, q + rows + 2, q + rows + 1))
        obj = self._object(name, verts, faces, cols, bone)
        mod = obj.modifiers.new("thickness", "SOLIDIFY"); mod.thickness = 0.012; mod.offset = 0
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.modifier_apply(modifier=mod.name)
        return obj

    def chain(self, name, bone, points, link, thickness, color, glow_every=0, glow=None):
        path = catmull(points, 64)
        lengths = [0.0]
        for p, q in zip(path, path[1:]):
            lengths.append(lengths[-1] + (q - p).length)
        step = link * 1.55
        count = int(lengths[-1] / step)
        objs = []
        for i in range(count + 1):
            d = i * step
            k = next(j for j in range(len(lengths)) if lengths[j] >= d or j == len(lengths) - 1)
            p = path[k]
            t = (path[min(k + 1, len(path) - 1)] - path[max(k - 1, 0)]).normalized()
            side = t.cross(Vector((0, 1, 0)) if abs(t.y) < 0.9 else Vector((1, 0, 0))).normalized()
            normal = side if i % 2 else t.cross(side).normalized()
            colour = glow if glow_every and i % glow_every == 0 else color
            objs.append(self.torus(f"{name}_{i:02d}", bone, p, normal, link * 0.5, thickness, colour, seg=10, sides=5, stretch=1.45, tangent=t))
        return objs


# ---------------------------------------------------------------- designs
class Body:
    """Surface queries on the real upright reference body (Godot coordinates)."""

    def __init__(self, verts, triangles):
        self.v = verts
        self.bvh = BVHTree.FromPolygons([Vector(p) for p in verts], triangles.tolist())

    def outer_hit(self, origin, direction, reach):
        """Outermost body surface on the ray origin + t * direction, 0 < t <= reach (or None)."""
        o, d = Vector(origin), Vector(direction).normalized()
        last, left = None, reach
        while left > 0:
            hit, _, _, dist = self.bvh.ray_cast(o, d, left)
            if hit is None:
                break
            last, o, left = hit, hit + d * 1e-4, left - dist - 1e-4
        return last

    def depth(self, x, y, side, gap=0.0, radius=0.05):
        m = (np.abs(self.v[:, 0] - x) < radius) & (np.abs(self.v[:, 1] - y) < radius)
        if not m.any():
            return self.depth(x, y, side, gap, radius * 1.6)
        z = self.v[m][:, 2]
        return float(z.max() + gap if side > 0 else z.min() - gap)

    def on_surface(self, xy_points, side, gap):
        return [(x, y, self.depth(x, y, side, gap)) for x, y in xy_points]


def mirror(fn):
    for s in (1, -1):
        fn(s)


def design_imp(b, body):
    # Demon child: a glowing spade on the tip of its own tail, facing front/back so the
    # player (who mostly sees their units from behind) reads it.
    tail = body.v[(body.v[:, 2] < -0.2) & (body.v[:, 1] < 0.75)]
    tip = tail[np.argmin(tail[:, 0])]
    tx, ty, tz = float(tip[0]), float(tip[1]), float(tip[2])
    spade = [(x * 1.35, y * 1.35) for x, y in [(0.0, 0.0), (0.07, 0.05), (0.10, 0.12), (0.05, 0.11), (0.0, 0.20), (-0.05, 0.11), (-0.10, 0.12), (-0.07, 0.05)]]
    b.plate("TailSpade", "pelvis", spade, (tx - 0.015, ty, tz), (0.8, 0.6, 0), (-0.6, 0.8, 0), (0, 0, 1), 0.025,
            PALETTE["violet"], edge=PALETTE["void"])


def design_mage(b, body):
    # Hexmage: a silence-rune halo standing behind the hood (reads from the back and the front).
    # On the head bone so it stays centred when the idle leans (on the chest it drifted, iteration 04).
    centre, radius = (-0.03, 1.13, body.depth(-0.03, 1.13, -1, 0.10)), 0.32
    b.torus("HaloRing", "head", centre, (0, 0, 1), radius, 0.019, PALETTE["violet"], seg=40, sides=6)
    b.torus("HaloInner", "head", centre, (0, 0, 1), radius * 0.78, 0.008, PALETTE["violet"], seg=32, sides=5)
    for k in range(8):
        a = 2 * math.pi * k / 8 + math.pi / 8
        out = Vector((math.cos(a), math.sin(a), 0))
        tangent = Vector((-math.sin(a), math.cos(a), 0))
        length = 0.12 if k % 2 else 0.075
        rune = [(-0.022, 0.0), (0.0, -0.018), (length, 0.0), (0.0, 0.018)]
        c = Vector(centre) + out * (radius + 0.005)
        b.plate(f"HaloRune{k}", "head", rune, tuple(c), tuple(out), tuple(tangent), (0, 0, 1), 0.016, PALETTE["violet"], edge=PALETTE["violet_dim"])


def design_scythe(b, body):
    # Ambusher: a reaper scythe slung diagonally across the back, blade arcing over the head.
    # Lower shaft kept short: a long butt swung out past the hip in attack (iteration 05).
    low, high = (-0.22, 0.74), (0.30, 1.78)
    z = min(body.depth(0.0, 1.10, -1, 0.10), -0.30)
    b.tube("ScytheShaft", "chest", [(low[0], low[1], z + 0.02), (0.04, 1.22, z), (high[0], high[1], z - 0.02)],
           [(0, 0.027), (1, 0.024)], [(0, PALETTE["steel"]), (0.92, PALETTE["steel"]), (1, PALETTE["violet"])], sides=7, samples=12)
    b.torus("ScytheGrip", "chest", (0.12, 1.42, z - 0.01), (0.45, 0.89, 0), 0.034, 0.01, PALETTE["violet"], seg=10, sides=5)
    blade = [(x * 1.25, y * 1.25) for x, y in [(0.0, -0.03), (0.10, 0.07), (0.28, 0.13), (0.48, 0.11), (0.66, 0.02), (0.78, -0.10),
                                               (0.62, -0.03), (0.44, 0.01), (0.25, 0.00), (0.08, -0.06)]]
    b.plate("ScytheBlade", "chest", blade, (high[0], high[1], z - 0.03), (-1, 0.08, 0), (0.08, 1, 0), (0, 0, 1), 0.018,
            PALETTE["steel"], edge=PALETTE["violet"])


def design_suc(b, body):
    # Succubus: a slim tail with a glowing heart, swung out beside the hip so it reads past the wings.
    path = [(0.0, 0.92, -0.14), (0.05, 0.80, -0.36), (0.25, 0.64, -0.52), (0.50, 0.66, -0.48), (0.60, 0.82, -0.38), (0.58, 0.96, -0.30)]
    b.tube("Tail", "pelvis", path, [(0, 0.030), (1, 0.016)], [(0, PALETTE["void"]), (0.45, PALETTE["void"]), (1, PALETTE["violet"])], sides=7, samples=20)
    heart = [(x * 1.5, y * 1.5) for x, y in [(0.0, -0.11), (0.08, -0.03), (0.10, 0.04), (0.07, 0.085), (0.03, 0.08), (0.0, 0.05), (-0.03, 0.08), (-0.07, 0.085), (-0.10, 0.04), (-0.08, -0.03)]]
    b.plate("TailHeart", "pelvis", heart, (0.57, 1.10, -0.28), (0.6, 0.0, -0.8), (0.0, 1.0, 0.0), (0.8, 0.0, 0.6), 0.03,
            PALETTE["violet"], edge=PALETTE["void"])


def design_fear(b, body):
    # Fear Demon: massive ram horns curling forward, the tips burning violet.
    def horn(s):
        b.tube("RamHorn", "head", [(s * 0.11, 1.27, 0.00), (s * 0.21, 1.41, -0.07), (s * 0.33, 1.39, -0.15),
                                   (s * 0.40, 1.24, -0.08), (s * 0.35, 1.11, 0.06), (s * 0.26, 1.10, 0.15)],
               [(0, 0.072), (0.5, 0.048), (1, 0.0)], [(0, PALETTE["bone"]), (0.72, PALETTE["bone"]), (1, PALETTE["violet"])], sides=9, samples=22, flat=0.85)
    mirror(horn)


def design_queen(b, body):
    # Pain Queen: a crown of thorns, tallest at the front, tips glowing violet.
    cx, cz, y, r = 0.01, 0.06, 1.56, 0.105
    b.torus("CrownBand", "head", (cx, y, cz), (0, 1, 0), r, 0.016, PALETTE["void"], seg=24, sides=6)
    for k in range(9):
        a = 2 * math.pi * k / 9 + math.pi / 2
        out = Vector((math.cos(a), 0, math.sin(a)))
        front = max(0.0, out.z)
        height = 0.12 + 0.11 * front
        base = Vector((cx, y, cz)) + out * r
        tip = base + out * 0.035 + Vector((0, height, 0))
        b.tube(f"CrownThorn{k}", "head", [tuple(base), tuple(base.lerp(tip, 0.5) + out * 0.012), tuple(tip)],
               [(0, 0.024), (1, 0.0)], [(0, PALETTE["void"]), (0.35, PALETTE["void"]), (1, PALETTE["violet"])], sides=5, samples=6)


def design_doom(b, body):
    # Doom Guard: the soul chain of its life link, worn as a bandolier over the left shoulder.
    # Sampled with a wide radius: the armour plates bulge between sample points (iteration 02 buried the chain).
    # Torso only: a segment over the shoulder floated off the raised pauldron in attack (iteration 05).
    path = [(0.16, 0.36), (0.08, 0.24), (0.0, 0.10), (-0.13, -0.02), (-0.22, -0.08)]
    front = [(x, y, body.depth(x, y, 1, 0.05, radius=0.09)) for x, y in path]
    back = [(x, y, body.depth(x, y, -1, 0.05, radius=0.09)) for x, y in path]
    b.chain("ChainFront", "chest", front, 0.10, 0.019, PALETTE["violet_dim"], glow_every=3, glow=PALETTE["violet"])
    b.chain("ChainBack", "chest", back, 0.10, 0.019, PALETTE["violet_dim"], glow_every=3, glow=PALETTE["violet"])


def design_dragon(b, body):
    # Black Dragon: humanoid kept; swept dragon horns, folded wings and a tail.
    def horn(s):
        b.tube("Horn", "head", [(s * 0.10, 1.60, 0.02), (s * 0.17, 1.76, -0.10), (s * 0.23, 1.88, -0.30), (s * 0.22, 1.90, -0.50)],
               [(0, 0.050), (0.6, 0.030), (1, 0.0)], [(0, PALETTE["horn"]), (0.65, PALETTE["horn"]), (1, PALETTE["violet"])], sides=8, samples=14)
    mirror(horn)

    def wing(s):
        # Folded dragon wing: the wrist arches above the shoulders, four fingers fan
        # down past the waist, skin spans arm -> fingers with a scalloped trailing edge.
        root, elbow, wrist = (s * 0.10, 1.30, -0.24), (s * 0.28, 1.66, -0.36), (s * 0.42, 1.94, -0.42)
        arm = [root, elbow, wrist]
        b.tube("WingArm", "chest", arm, [(0, 0.045), (1, 0.030)], [(0, PALETTE["iron"]), (1, PALETTE["iron"])], sides=7, samples=10)
        b.tube("WingClaw", "chest", [wrist, (s * 0.45, 2.04, -0.40), (s * 0.43, 2.10, -0.36)], [(0, 0.026), (1, 0.0)],
               [(0, PALETTE["iron"]), (1, PALETTE["violet"])], sides=6, samples=6)
        tips = [(s * 0.74, 1.10, -0.38), (s * 0.66, 0.78, -0.42), (s * 0.48, 0.62, -0.45), (s * 0.28, 0.74, -0.45)]
        spars = []
        for k, tip in enumerate(tips):
            bow = 0.06 - 0.015 * k
            mid = (lerp(wrist[0], tip[0], 0.5) + s * bow, lerp(wrist[1], tip[1], 0.5), lerp(wrist[2], tip[2], 0.5) - 0.02)
            spars.append([tuple(p) for p in catmull([wrist, mid, tip], 10)])
            b.tube(f"WingFinger{k}", "chest", [wrist, mid, tip], [(0, 0.022), (1, 0.007)],
                   [(0, PALETTE["iron"]), (1, PALETTE["violet_dim"])], sides=5, samples=10)
        spars.append([tuple(p) for p in catmull([wrist, elbow, root], 10)])
        b.membrane("WingSkin", "chest", wrist, spars, PALETTE["membrane"], PALETTE["violet_dim"], sag=0.14)
    mirror(wing)
    b.tube("Tail", "pelvis", [(0.0, 0.92, -0.16), (0.0, 0.70, -0.40), (0.10, 0.36, -0.62), (0.26, 0.12, -0.78), (0.42, 0.05, -0.84)],
           [(0, 0.075), (0.5, 0.045), (1, 0.0)], [(0, PALETTE["horn"]), (0.8, PALETTE["horn"]), (1, PALETTE["violet"])], sides=8, samples=18)


def design_undead_poison(b, body):
    # Poisoner: a glowing poison flask hung at the back of the right hip (front and back read it).
    x, y = -0.23, 0.56
    z = body.depth(x, y, -1, 0.10, radius=0.08)
    bottom, top = (x, y - 0.24, z), (x, y + 0.27, z)
    b.tube("FlaskGlass", "pelvis", [bottom, top], [(0, 0.04), (0.12, 0.14), (0.45, 0.16), (0.70, 0.10), (0.80, 0.05), (1, 0.048)],
           [(0, TOXIC["toxic"]), (0.68, TOXIC["toxic"]), (0.72, TOXIC["glass"]), (1, TOXIC["glass"])], sides=10, samples=14)
    b.tube("FlaskCork", "pelvis", [top, (x, y + 0.35, z)], [(0, 0.054), (1, 0.042)], [(0, TOXIC["olive"]), (1, TOXIC["olive"])], sides=8, samples=3)
    b.torus("FlaskStrap", "pelvis", (x, y + 0.19, z), (0, 1, 0), 0.07, 0.016, TOXIC["bone"], seg=14, sides=5)


def design_undead_parasite(b, body):
    # Parasite: glowing brood pods on the back under the flame collar, trailing tendrils.
    pods = [(0.15, 0.86, 0.15), (-0.14, 0.82, 0.14), (0.0, 0.66, 0.13)]
    for k, (x, y, r) in enumerate(pods):
        z = body.depth(x, y, -1, 0.0, radius=0.07) + r * 0.4
        start, end = (x, y, z), (x * 1.15, y - 0.03, z - r * 2.1)
        # Graded so the sac keeps its form (fully glowing pods read as flat blocks, iteration 02).
        b.tube(f"Pod{k}", "chest", [start, end], [(0, r * 0.45), (0.4, r), (0.8, r * 0.7), (1, 0.0)],
               [(0, TOXIC["olive"]), (0.35, TOXIC["glass"]), (0.8, TOXIC["toxic_dim"]), (1, TOXIC["toxic"])], sides=12, samples=12)
        b.tube(f"Tendril{k}", "chest", [(x, y - r * 0.6, z - r * 0.4), (x * 1.3, y - 0.14, z - r * 0.9), (x * 1.6, y - 0.26, z - r * 0.4)],
               [(0, 0.016), (1, 0.0)], [(0, TOXIC["olive"]), (1, TOXIC["toxic_dim"])], sides=5, samples=8)


def design_undead_spike(b, body):
    # Spike thrower: a fan of javelins on the back, heads glowing above the hood.
    base = Vector((0.0, 0.80, body.depth(0.0, 0.85, -1, 0.05, radius=0.08)))
    head = [(0.0, -0.05), (0.035, 0.03), (0.0, 0.16), (-0.035, 0.03)]
    for k, angle in enumerate((-38, -19, 0, 19, 38)):
        a = math.radians(angle)
        d = Vector((math.sin(a), math.cos(a), -0.28)).normalized()
        start, tip = base + d * 0.08, base + d * 1.02
        b.tube(f"Javelin{k}", "chest", [tuple(start), tuple(tip)], [(0, 0.022), (1, 0.019)],
               [(0, TOXIC["bone"]), (1, TOXIC["bone"])], sides=6, samples=4)
        side = d.cross(Vector((0, 0, 1))).normalized()
        b.plate(f"JavelinHead{k}", "chest", head, tuple(tip), tuple(side), tuple(d), tuple(side.cross(d).normalized()), 0.016,
                TOXIC["toxic"], edge=TOXIC["olive"])


def design_undead_bomb(b, body):
    # Bomb: a sparking fuse on the gem atop its round bomb head, and a glowing core on the chest.
    top = body.v[np.argmax(np.where(np.abs(body.v[:, 0]) < 0.12, body.v[:, 1], -9))]
    tx, ty, tz = float(top[0]), float(top[1]), float(top[2])
    b.tube("Fuse", "head", [(tx, ty - 0.03, tz), (tx + 0.03, ty + 0.08, tz - 0.02), (tx + 0.09, ty + 0.14, tz - 0.05)],
           [(0, 0.016), (1, 0.012)], [(0, TOXIC["olive"]), (0.85, TOXIC["olive"]), (1, TOXIC["toxic"])], sides=6, samples=8)
    spark = (tx + 0.11, ty + 0.16, tz - 0.06)
    b.tube("FuseSpark", "head", [(spark[0] - 0.045, spark[1], spark[2]), (spark[0] + 0.045, spark[1], spark[2])],
           [(0, 0.0), (0.5, 0.05), (1, 0.0)], [(0, TOXIC["toxic"]), (1, TOXIC["toxic"])], sides=8, samples=7)
    zc = body.depth(0.0, 0.92, 1, -0.03, radius=0.07)
    b.tube("Core", "chest", [(0.0, 0.92, zc - 0.05), (0.0, 0.92, zc + 0.11)], [(0, 0.0), (0.5, 0.085), (1, 0.0)],
           [(0, TOXIC["toxic"]), (1, TOXIC["toxic"])], sides=10, samples=9)
    b.torus("CoreRing", "chest", (0.0, 0.92, zc + 0.03), (0, 0, 1), 0.085, 0.016, TOXIC["olive"], seg=16, sides=6)


def design_undead_titan(b, body):
    # Armoured tank: a ridge of bone spikes rising from the upper back, toxic tips.
    rows = [(0.0, 1.30, 0.34), (0.14, 1.24, 0.28), (-0.14, 1.24, 0.28), (0.24, 1.15, 0.22), (-0.24, 1.15, 0.22), (0.0, 1.12, 0.26)]
    for k, (x, y, length) in enumerate(rows):
        z = body.depth(x, y, -1, -0.02, radius=0.07)
        d = Vector((x * 0.9, 0.75, -0.75)).normalized()
        start = Vector((x, y, z))
        b.tube(f"DorsalSpike{k}", "chest", [tuple(start), tuple(start + d * length * 0.55 + Vector((0, 0.03, 0))), tuple(start + d * length)],
               [(0, 0.05), (0.6, 0.026), (1, 0.0)], [(0, TOXIC["bone"]), (0.7, TOXIC["bone"]), (1, TOXIC["toxic"])], sides=7, samples=8)


def design_undead_mother(b, body):
    # Brood mother (T3): a crown of toxic flame-horns ringing the top of her hood.
    # Horns grow straight out of the hood: a band ring read as a floating bar (iterations 01-02).
    # The hood centre comes from the hood alone: at these heights the rest pose also holds the
    # staff side (x < -0.4), which pulled the old ring centroid 0.28 off the head and left the
    # horns floating beside the hood in every view (device test, 2026-10-05).
    y0 = 1.50
    crown = body.v[body.v[:, 1] > 1.75]
    hx, hz = float(np.median(crown[:, 0])), float(np.median(crown[:, 2]))
    ring = body.v[(np.abs(body.v[:, 1] - y0) < 0.03) & (np.hypot(body.v[:, 0] - hx, body.v[:, 2] - hz) < 0.45)]
    centre = Vector(((ring[:, 0].min() + ring[:, 0].max()) / 2, y0, (ring[:, 2].min() + ring[:, 2].max()) / 2))
    for k in range(7):
        a = 2 * math.pi * k / 7 + math.pi / 2
        out = Vector((math.cos(a), 0, math.sin(a)))
        front = max(0.0, out.z)
        height = 0.30 + 0.12 * front
        # Root each horn on the outermost hood surface in its own direction, sunk in slightly;
        # the hood is too low-poly here for per-direction vertex radii.
        hit = body.outer_hit(centre, out, 0.45)
        if hit is None:
            raise RuntimeError(f"CrownHorn{k}: no hood surface within 0.45 of {tuple(centre)}")
        base = hit - out * 0.025
        bend = base + out * 0.06 + Vector((0, height * 0.55, 0))
        tip = base + out * 0.03 + Vector((0, height, 0))
        b.tube(f"CrownHorn{k}", "head", [tuple(base), tuple(bend), tuple(tip)], [(0, 0.04), (1, 0.0)],
               [(0, TOXIC["olive"]), (0.4, TOXIC["toxic_dim"]), (1, TOXIC["toxic"])], sides=6, samples=8)


DESIGNS = {"dark_imp": design_imp, "dark_mage": design_mage, "dark_scythe": design_scythe, "dark_suc": design_suc,
           "dark_fear": design_fear, "dark_queen": design_queen, "dark_doom": design_doom, "dark_dragon": design_dragon,
           "undead_poison": design_undead_poison, "undead_parasite": design_undead_parasite, "undead_spike": design_undead_spike,
           "undead_bomb": design_undead_bomb, "undead_titan": design_undead_titan, "undead_mother": design_undead_mother}


# ---------------------------------------------------------------- rig plumbing
def read_glb_mesh(path: Path):
    """Positions and triangles of every primitive, raw glTF space (= Godot coordinates)."""
    data = path.read_bytes()
    length = struct.unpack_from("<I", data, 8)[0]
    offset, chunks = 12, {}
    while offset < length:
        size, kind = struct.unpack_from("<II", data, offset)
        chunks[kind] = data[offset + 8: offset + 8 + size]
        offset += 8 + size
    doc, blob = json.loads(chunks[0x4E4F534A]), chunks[0x004E4942]

    def accessor(index, width, dtype):
        acc = doc["accessors"][index]
        view = doc["bufferViews"][acc["bufferView"]]
        start = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
        stride = view.get("byteStride", 0) or width
        raw = np.frombuffer(blob, dtype=np.uint8, count=stride * (acc["count"] - 1) + width, offset=start)
        rows = np.lib.stride_tricks.as_strided(raw, shape=(acc["count"], width), strides=(stride, 1))
        return np.ascontiguousarray(rows).view(dtype)

    verts, tris, base = [], [], 0
    for mesh in doc["meshes"]:
        for prim in mesh["primitives"]:
            positions = accessor(prim["attributes"]["POSITION"], 12, np.float32).reshape(-1, 3)
            if "indices" in prim:
                kind = doc["accessors"][prim["indices"]]["componentType"]
                width, dtype = {5121: (1, np.uint8), 5123: (2, np.uint16), 5125: (4, np.uint32)}[kind]
                index = accessor(prim["indices"], width, dtype).reshape(-1).astype(np.int64)
            else:
                index = np.arange(len(positions))
            if prim.get("mode", 4) == 4:
                tris.append(index.reshape(-1, 3) + base)
            verts.append(positions)
            base += len(positions)
    return np.concatenate(verts), np.concatenate(tris)


def read_glb_positions(path: Path):
    return read_glb_mesh(path)[0]


def nearest(src, dst):
    """Index into dst of each src point's nearest neighbour (brute force, chunked)."""
    out = np.empty(len(src), dtype=np.int64)
    for start in range(0, len(src), 512):
        d = ((src[start:start + 512, None, :] - dst[None, :, :]) ** 2).sum(-1)
        out[start:start + 512] = d.argmin(1)
    return out


def align_translation(base, verts):
    """Translation-only ICP: action files re-export the same body in another place and
    vertex order. Returns (offset taking base into verts, max nearest-point residual)."""
    offset = verts.mean(0) - base.mean(0)
    if len(base) == len(verts) and np.abs((verts - offset) - base).max() < 1e-4:
        return offset, {"median": 0.0, "p99": 0.0, "max": 0.0}
    for _ in range(6):
        idx = nearest(base + offset, verts)
        offset = (verts[idx] - base).mean(0)
    idx = nearest(base + offset, verts)
    r = np.sqrt(((verts[idx] - base - offset) ** 2).sum(-1))
    return offset, {"median": float(np.median(r)), "p99": float(np.percentile(r, 99)), "max": float(r.max())}


def xform(d):
    return Matrix(((d["basis_x"][0], d["basis_y"][0], d["basis_z"][0], d["origin"][0]),
                   (d["basis_x"][1], d["basis_y"][1], d["basis_z"][1], d["origin"][1]),
                   (d["basis_x"][2], d["basis_y"][2], d["basis_z"][2], d["origin"][2]),
                   (0, 0, 0, 1)))


def family(bone_names):
    if any(n.startswith("CC_Base_") for n in bone_names):
        return "cc"
    if any(n.startswith("mixamorig_") for n in bone_names):
        return "mixamo"
    return "bare"


def rigs(refs: Path, unit: str):
    rig = json.loads((refs / unit / "rig.json").read_text(encoding="utf-8"))
    base = read_glb_positions(refs / unit / "reference_0.glb")
    out = {}
    for skel in rig["skeletons"]:
        ref = skel["reference"]
        if ref in out:
            out[ref]["skeletons"].append(skel["path"])
            continue
        verts = read_glb_positions(refs / unit / ref)
        offset, residual = align_translation(base, verts)
        out[ref] = {"skeletons": [skel["path"]], "offset": offset.tolist(), "residual": residual,
                    "family": family([bn["name"] for bn in skel["bones"]]),
                    "rest": {bn["name"]: xform(bn["global_rest"]) for bn in skel["bones"]},
                    "bind": {bd["bone"]: bd["pose"] for bd in skel["binds"]}}
    return out


# ---------------------------------------------------------------- main
def main():
    argv = sys.argv[sys.argv.index("--") + 1:]
    parser = argparse.ArgumentParser()
    parser.add_argument("--unit", required=True)
    parser.add_argument("--refs", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--render", action="store_true")
    a = parser.parse_args(argv)
    refs, out = Path(a.refs), Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(refs / a.unit / "reference_0.glb"))
    for obj in bpy.context.scene.objects:
        obj["role"] = "original_body_reference (not exported)"
    material = bpy.data.materials.new("DarkPartsPalette")
    material.use_nodes = True
    nodes = material.node_tree.nodes
    vc = nodes.new("ShaderNodeVertexColor"); vc.layer_name = "Color"
    material.node_tree.links.new(vc.outputs["Color"], nodes["Principled BSDF"].inputs["Base Color"])
    builder = Builder()
    DESIGNS[a.unit](builder, Body(*read_glb_mesh(refs / a.unit / "reference_0.glb")))
    authoring = bpy.data.collections.new("AUTHORING - editable dark parts")
    bpy.context.scene.collection.children.link(authoring)
    for obj, _ in builder.parts:
        for col in list(obj.users_collection):
            col.objects.unlink(obj)
        authoring.objects.link(obj)
        obj.data.materials.append(material)
    bpy.ops.wm.save_as_mainfile(filepath=str(out / f"{a.unit}_parts_source.blend"))

    if a.render:
        render_views(out, a.unit)

    rig_sets = rigs(refs, a.unit)
    exports, manifest = [], {"unit": a.unit, "blender": bpy.app.version_string, "rigs": [], "parts": [o.name for o, _ in builder.parts]}
    for index, (ref, rig) in enumerate(rig_sets.items()):
        # Same body re-exported elsewhere: nearly every vertex must land (a few re-rigged
        # arm vertices differ by ~2 cm in the succubus/doom run files).
        if rig["residual"]["median"] > 0.002 or rig["residual"]["p99"] > 0.02:
            raise RuntimeError(f"{ref}: body differs from reference_0 beyond a translation {rig['residual']}")
        offset = Vector(rig["offset"])
        row = {"reference": ref, "skeletons": rig["skeletons"], "family": rig["family"], "offset": rig["offset"], "residual": rig["residual"], "bones": []}
        by_bone = {}
        for obj, logical in builder.parts:
            by_bone.setdefault(logical, []).append(obj)
        for logical, objs in by_bone.items():
            bone = LOGICAL[logical][rig["family"]]
            if bone not in rig["rest"] or bone not in rig["bind"]:
                raise RuntimeError(f"{ref}: rig lacks bound bone {bone}")
            bpy.ops.object.select_all(action="DESELECT")
            copies = []
            for obj in objs:
                dup = obj.copy(); dup.data = obj.data.copy()
                bpy.context.scene.collection.objects.link(dup)
                dup.select_set(True); copies.append(dup)
            bpy.context.view_layer.objects.active = copies[0]
            if len(copies) > 1:
                bpy.ops.object.join()
            joined = bpy.context.view_layer.objects.active
            joined.name = f"r{index}_{bone}"
            # Blender -> Godot upright, into this rig's body space, then bone-rest-local, back to Blender.
            to_local = C @ rig["rest"][bone].inverted() @ Matrix.Translation(offset) @ C_INV
            joined.data.transform(to_local)
            mod = joined.modifiers.new("triangulate", "TRIANGULATE")
            bpy.ops.object.modifier_apply(modifier=mod.name)
            pose = rig["bind"][bone]
            joined["bone"] = bone
            joined["bind"] = [*pose["basis_x"], *pose["basis_y"], *pose["basis_z"], *pose["origin"]]
            for key in ("logical_bone",):
                if key in joined:
                    del joined[key]
            exports.append(joined)
            row["bones"].append({"bone": bone, "vertices": len(joined.data.vertices), "triangles": len(joined.data.polygons)})
        manifest["rigs"].append(row)
    bpy.ops.object.select_all(action="DESELECT")
    for obj in exports:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = exports[0]
    glb = out / f"{a.unit}_parts.glb"
    bpy.ops.export_scene.gltf(filepath=str(glb), export_format="GLB", use_selection=True, export_animations=False,
                              export_skins=False, export_yup=True, export_materials="NONE", export_vertex_color="ACTIVE",
                              export_all_vertex_colors=False, export_extras=True, export_normals=True)
    if not glb.is_file() or glb.stat().st_size < 1024:
        raise RuntimeError("GLB export missing")
    manifest["runtime_triangles_per_rig"] = [sum(b["triangles"] for b in r["bones"]) for r in manifest["rigs"]]
    (out / "parts-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print("DARK_PARTS_COMPLETE", json.dumps({"unit": a.unit, "glb": str(glb), "rigs": len(manifest["rigs"]), "triangles": manifest["runtime_triangles_per_rig"]}))


def render_views(out: Path, unit: str):
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "TEXTURE"
    scene.render.resolution_x, scene.render.resolution_y = 900, 900
    scene.render.film_transparent = False
    cam_data = bpy.data.cameras.new("cam"); cam_data.type = "ORTHO"; cam_data.ortho_scale = 2.6
    cam = bpy.data.objects.new("cam", cam_data); scene.collection.objects.link(cam); scene.camera = cam
    target = Vector((0, 0, 1.0))
    for obj in scene.objects:
        if obj.type == "MESH" and obj.get("role"):
            target = Vector((0, 0, (obj.bound_box[0][2] + obj.bound_box[1][2]) * 0.5 + 0.0))
    for view, direction in {"front": Vector((0, -1, 0)), "back": Vector((0, 1, 0)), "side": Vector((1, 0, 0)), "three_quarter_back": Vector((0.7, 0.7, 0.25))}.items():
        cam.location = Vector((0, 0, 0.95)) + direction.normalized() * 6
        cam.rotation_euler = (Vector((0, 0, 0.95)) - cam.location).to_track_quat("-Z", "Y").to_euler()
        scene.render.filepath = str(out / f"render_{view}.png")
        bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
    main()
