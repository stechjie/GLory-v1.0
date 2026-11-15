"""Lantern · Red Order —— 程序化建模脚本（Blender 5.x，后台运行）。

用法：
  blender --background --python-exit-code 1 --python build_lantern.py [-- --no-render]

产物（都在脚本同目录）：
  lantern_red_order.blend   可编辑源文件
  lantern_red_order.glb     运行时模型（朝向 glTF +Z，脚底为原点，身高约 1.05）
  previews/*.png            四视图 + 主视角预览

约定：Blender 里角色面朝 -Y，+X 是角色左手（正面看在画面右侧，提灯那只手）。
全部用纯色材质，不依赖贴图；灯笼是独立物体 Lantern_Prop，方便游戏里单独挂点或隐藏。
"""

import math
import os
import random
import sys

import bmesh
import bpy
from mathutils import Vector

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
DO_RENDER = "--no-render" not in ARGS
random.seed(7)

X, Y, Z = Vector((1, 0, 0)), Vector((0, 1, 0)), Vector((0, 0, 1))
TAU = math.tau
GROUPS = {}


# ----------------------------------------------------------------------------
# 材质
# ----------------------------------------------------------------------------
def _lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hexrgb(h):
    h = h.lstrip("#")
    return tuple(_lin(int(h[i:i + 2], 16) / 255.0) for i in (0, 2, 4)) + (1.0,)


def make_mat(name, hexcol, rough=0.6, metal=0.0, emit=None, emit_strength=0.0):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = next(n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Base Color"].default_value = hexrgb(hexcol)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    if emit:
        bsdf.inputs["Emission Color"].default_value = hexrgb(emit)
        bsdf.inputs["Emission Strength"].default_value = emit_strength
    mat.diffuse_color = hexrgb(hexcol)
    mat.use_backface_culling = False
    return mat


def build_materials():
    m = {}
    m["skin"] = make_mat("M_Skin", "#FFD6C2", 0.55)
    m["hair_dark"] = make_mat("M_HairDark", "#3A1220", 0.45)
    m["hair_red"] = make_mat("M_HairRed", "#B4132A", 0.4)
    m["black"] = make_mat("M_ClothBlack", "#231519", 0.7)
    m["red"] = make_mat("M_ClothRed", "#9A1828", 0.65)
    m["deep_red"] = make_mat("M_ClothDeepRed", "#5E0F1C", 0.7)
    m["gold"] = make_mat("M_Gold", "#E2B255", 0.35, 0.85)
    m["fur"] = make_mat("M_FurWhite", "#F7F0EC", 0.85)
    m["white"] = make_mat("M_EyeWhite", "#FFFFFF", 0.4, emit="#FFFFFF", emit_strength=0.25)
    m["iris"] = make_mat("M_Iris", "#D9162A", 0.3, emit="#D9162A", emit_strength=0.6)
    m["iris_lo"] = make_mat("M_IrisLow", "#FF7A66", 0.3, emit="#FF7A66", emit_strength=0.8)
    m["line"] = make_mat("M_FaceLine", "#2A0B12", 0.6)
    m["sigil"] = make_mat("M_Sigil", "#E0162A", 0.4, emit="#FF1A30", emit_strength=2.0)
    m["gem"] = make_mat("M_Gem", "#D2142A", 0.15, emit="#D2142A", emit_strength=0.8)
    m["glow"] = make_mat("M_LanternGlow", "#E0241C", 0.3, emit="#FF3018", emit_strength=4.0)
    m["cross"] = make_mat("M_LanternCross", "#FFE0A0", 0.3, emit="#FFD890", emit_strength=10.0)
    return m


# ----------------------------------------------------------------------------
# 几何工具
# ----------------------------------------------------------------------------
def finish(name, bm, mat, group, flat=False):
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    me.polygons.foreach_set("use_smooth", [not flat] * len(me.polygons))
    me.materials.append(mat)
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    GROUPS.setdefault(group, []).append(ob)
    return ob


def cr(vals, sub):
    """Catmull-Rom 重采样，Vector 和 float 都能用。"""
    if sub <= 1 or len(vals) < 2:
        return list(vals)
    out, n = [], len(vals)
    for i in range(n - 1):
        p0, p1, p2, p3 = vals[max(i - 1, 0)], vals[i], vals[i + 1], vals[min(i + 2, n - 1)]
        for k in range(sub):
            t = k / sub
            out.append(0.5 * ((2 * p1) + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                              + (3 * p1 - p0 - 3 * p2 + p3) * t ** 3))
    out.append(vals[-1])
    return out


def _aslist(v, n):
    return list(v) if isinstance(v, (list, tuple)) else [v] * n


def tube(name, pts, r1, r2=None, mat=None, group="Outfit", sides=10, up=Z, normals=None,
         sub=1, closed=False, cap=(True, True), flat=False):
    """沿折线扫出椭圆截面管。r1 沿参考法线方向，r2 沿与之垂直的方向；半径为 0 的端点收成尖。"""
    n = len(pts)
    pts = [Vector(p) for p in pts]
    r1 = _aslist(r1, n)
    r2 = _aslist(r2 if r2 is not None else r1, n)
    nr = [Vector(v) for v in normals] if isinstance(normals, list) else None
    if sub > 1 and not closed:
        pts, r1, r2 = cr(pts, sub), [max(0.0, v) for v in cr(r1, sub)], [max(0.0, v) for v in cr(r2, sub)]
        r1[-1], r2[-1] = max(0.0, _aslist(r1, 1)[-1]), max(0.0, r2[-1])
        if nr:
            nr = cr(nr, sub)
        n = len(pts)
    ref = Vector(normals) if (normals is not None and nr is None) else Vector(up)
    bm = bmesh.new()
    rings, prev_n = [], None
    for i in range(n):
        a = pts[(i - 1) % n] if (closed or i > 0) else pts[i]
        b = pts[(i + 1) % n] if (closed or i < n - 1) else pts[i]
        t = (b - a).normalized()
        base = nr[i] if nr else ref
        n1 = base - t * base.dot(t)
        if n1.length < 1e-5:
            n1 = prev_n if prev_n is not None else t.orthogonal()
        n1.normalize()
        prev_n = n1
        n2 = t.cross(n1)
        if max(r1[i], r2[i]) < 1e-6:
            rings.append([bm.verts.new(pts[i])])
        else:
            rings.append([bm.verts.new(pts[i] + n1 * (math.cos(TAU * k / sides) * r1[i])
                                       + n2 * (math.sin(TAU * k / sides) * r2[i])) for k in range(sides)])
    pairs = [(i, i + 1) for i in range(n - 1)] + ([(n - 1, 0)] if closed else [])
    for i, j in pairs:
        A, B = rings[i], rings[j]
        if len(A) == 1 and len(B) == 1:
            continue
        for k in range(sides):
            k2 = (k + 1) % sides
            if len(A) == 1:
                bm.faces.new((A[0], B[k], B[k2]))
            elif len(B) == 1:
                bm.faces.new((A[k], A[k2], B[0]))
            else:
                bm.faces.new((A[k], A[k2], B[k2], B[k]))
    if not closed:
        if cap[0] and len(rings[0]) > 1:
            bm.faces.new(rings[0])
        if cap[1] and len(rings[-1]) > 1:
            bm.faces.new(rings[-1])
    return finish(name, bm, mat, group, flat)


def ellipsoid(name, c, radii, mat, group="Body", basis=None, segs=20, rings=10, flat=False):
    bx, by, bz = basis if basis else (X, Y, Z)
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=rings, radius=1.0)
    c = Vector(c)
    for v in bm.verts:
        co = v.co.copy()
        v.co = c + bx * (co.x * radii[0]) + by * (co.y * radii[1]) + bz * (co.z * radii[2])
    return finish(name, bm, mat, group, flat)


def ring(name, c, axis, R, r, mat, group="Outfit", ry=None, sides=6, segs=24, u=None):
    """金属环：圆心 c、法线 axis、主半径 R（ry 给第二主半径可做椭圆）。"""
    axis = Vector(axis).normalized()
    u = (Vector(u) - axis * Vector(u).dot(axis)).normalized() if u is not None else axis.orthogonal().normalized()
    v = axis.cross(u)
    ry = R if ry is None else ry
    pts = [Vector(c) + u * (math.cos(TAU * k / segs) * R) + v * (math.sin(TAU * k / segs) * ry) for k in range(segs)]
    return tube(name, pts, r, mat=mat, group=group, sides=sides, normals=axis, closed=True)


def lathe(name, profile, mat, group="Outfit", segs=32, a0=0.0, a1=TAU, rf=None, zf=None, ry=1.0, psub=3):
    """绕 Z 旋转成面。a=0 是正前方(-Y)。rf/zf(a, frac) 给褶皱和锯齿下摆。返回 (物体, 下摆点列, 首列, 末列)。"""
    prof = cr([Vector((r, z)) for r, z in profile], psub)
    n = len(prof)
    full = abs((a1 - a0) - TAU) < 1e-6
    cols = segs if full else segs + 1
    bm = bmesh.new()
    grid, pos = [], []
    for j in range(cols):
        a = a0 + (a1 - a0) * j / segs
        col, pcol = [], []
        for k in range(n):
            frac = k / (n - 1)
            rr = prof[k].x * (rf(a, frac) if rf else 1.0)
            zz = prof[k].y + (zf(a, frac) if zf else 0.0)
            p = Vector((rr * math.sin(a), -rr * math.cos(a) * ry, zz))
            pcol.append(p)
            col.append(bm.verts.new(p))
        grid.append(col)
        pos.append(pcol)
    for j in range(cols if full else cols - 1):
        j2 = (j + 1) % cols
        for k in range(n - 1):
            bm.faces.new((grid[j][k], grid[j2][k], grid[j2][k + 1], grid[j][k + 1]))
    ob = finish(name, bm, mat, group)
    return ob, [c[-1] for c in pos], pos[0], pos[-1]


def tassel(name, top, length=0.07, r=0.014, group="Outfit"):
    top = Vector(top)
    tube(name + "_cord", [top + Z * 0.02, top], 0.002, mat=M["gold"], group=group, sides=4)
    ellipsoid(name + "_bead", top, (0.008, 0.008, 0.008), M["gold"], group, segs=8, rings=6)
    tube(name + "_fringe", [top - Z * 0.004, top - Z * 0.02, top - Z * (length * 0.6), top - Z * length],
         [r * 0.45, r * 0.9, r, r * 0.75], mat=M["red"], group=group, sides=8, normals=Y)


def tri(x):
    return 2.0 * abs((x % 1.0) - 0.5)


# ----------------------------------------------------------------------------
# 头部坐标系：头是椭球，(phi, theta) = (方位角，0 为正前；仰角)
# ----------------------------------------------------------------------------
HC = Vector((0, 0, 0.728))
HR = Vector((0.182, 0.174, 0.17))


def hdir(phi, theta):
    p, t = math.radians(phi), math.radians(theta)
    return Vector((math.sin(p) * math.cos(t), -math.cos(p) * math.cos(t), math.sin(t)))


def hpt(phi, theta, scale=1.0):
    d = hdir(phi, theta)
    return HC + Vector((d.x * HR.x, d.y * HR.y, d.z * HR.z)) * scale


def hframe(phi, theta, roll=0.0):
    d = hdir(phi, theta)
    n = Vector((d.x / HR.x, d.y / HR.y, d.z / HR.z)).normalized()
    r = Z.cross(n).normalized()
    u = n.cross(r)
    a = math.radians(roll)
    return r * math.cos(a) + u * math.sin(a), u * math.cos(a) - r * math.sin(a), n


def decal(name, phi, theta, w, h, mat, off=0.0, thick=0.005, roll=0.0, dx=0.0, dy=0.0, segs=12, rings=6,
          flat=False, group="Face"):
    r, u, n = hframe(phi, theta, roll)
    c = hpt(phi, theta) + r * dx + u * dy + n * (off - (dx * dx + dy * dy) / 0.38)
    return ellipsoid(name, c, (w, h, thick), mat, group, basis=(r, u, n), segs=segs, rings=rings, flat=flat)


def hline(name, phi, theta, pts2d, rad, mat, off=0.004, roll=0.0, sub=3, group="Face"):
    r, u, n = hframe(phi, theta, roll)
    c = hpt(phi, theta)
    pts = [c + r * dx + u * dy + n * (off - (dx * dx + dy * dy) / 0.38) for dx, dy in pts2d]
    return tube(name, pts, rad, [v * 0.6 for v in _aslist(rad, len(pts))], mat=mat, group=group, sides=6,
                normals=u, sub=sub)


# ----------------------------------------------------------------------------
# 各部件
# ----------------------------------------------------------------------------
def build_body():
    g = "Body"
    ellipsoid("Head", HC, HR, M["skin"], g, segs=32, rings=18)
    tube("Neck", [(0, 0, 0.51), (0, 0, 0.58)], 0.028, mat=M["skin"], group=g)
    tube("Torso", [(0, 0, 0.36), (0, 0, 0.41), (0, 0, 0.46), (0, 0, 0.505), (0, 0, 0.53)],
         [0.07, 0.058, 0.064, 0.056, 0.03], [0.085, 0.074, 0.084, 0.08, 0.035],
         mat=M["skin"], group=g, sides=16, normals=Y, sub=3)
    for s in (-1, 1):
        sn = "L" if s > 0 else "R"
        ellipsoid("Shoulder_" + sn, (s * 0.092, 0, 0.502), (0.034, 0.034, 0.034), M["skin"], g, segs=12, rings=8)
        tube("Arm_" + sn, [(s * 0.095, 0, 0.50), (s * 0.165, 0, 0.43), (s * 0.24, -0.02, 0.36)],
             [0.03, 0.027, 0.022], mat=M["skin"], group=g, sides=10, sub=2)
        ellipsoid("Hand_" + sn, (s * 0.258, -0.026, 0.342), (0.027, 0.027, 0.033), M["skin"], g, segs=12, rings=8)
        tube("Thigh_" + sn, [(s * 0.058, 0, 0.38), (s * 0.064, 0, 0.27), (s * 0.066, 0, 0.17)],
             [0.054, 0.05, 0.044], mat=M["skin"], group=g, sides=14, sub=2)
        # 尖耳 + 金耳套
        root = hpt(s * 88, -4, 0.93)
        tip = HC + Vector((s * 0.315, 0.035, 0.055))
        mid = root.lerp(tip, 0.5) + Vector((0, 0, 0.004))
        tube("Ear_" + sn, [root, mid, tip], [0.032, 0.022, 0.0], [0.014, 0.009, 0.0], mat=M["skin"], group=g,
             sides=10, sub=3)
        tube("EarCuff_" + sn, [root.lerp(tip, 0.58), root.lerp(tip, 0.8) + Z * 0.002, tip + (tip - root) * 0.05],
             [0.021, 0.015, 0.0], [0.012, 0.009, 0.0], mat=M["gold"], group="Outfit", sides=8, sub=3)


def build_face():
    for s in (-1, 1):
        sn = "L" if s > 0 else "R"
        phi, th = s * 24, -9
        decal("EyeWhite_" + sn, phi, th, 0.037, 0.045, M["white"], off=0.0005, thick=0.005, roll=-s * 6)
        decal("Iris_" + sn, phi, th, 0.028, 0.038, M["iris"], off=0.003, thick=0.005, dy=-0.003)
        decal("IrisLow_" + sn, phi, th, 0.019, 0.012, M["iris_lo"], off=0.0055, thick=0.004, dy=-0.024)
        decal("Pupil_" + sn, phi, th, 0.011, 0.02, M["line"], off=0.0058, thick=0.004, dy=-0.002)
        decal("EyeGlint_" + sn, phi, th, 0.009, 0.011, M["white"], off=0.0085, thick=0.003, dx=-0.012, dy=0.016)
        decal("EyeGlint2_" + sn, phi, th, 0.004, 0.005, M["white"], off=0.0085, thick=0.003, dx=0.012, dy=-0.014)
        # q 轴：内眼角为负、外眼角为正；上眼线压平出“冷脸”感
        lid = [(-0.043, 0.020), (-0.022, 0.039), (0.010, 0.043), (0.038, 0.030), (0.054, 0.037)]
        hline("Lid_" + sn, phi, th, [(s * q, y) for q, y in lid], [0.004, 0.0075, 0.0075, 0.006, 0.0],
              M["line"], off=0.006)
        hline("LidLow_" + sn, phi, th, [(s * 0.012, -0.043), (s * 0.032, -0.034)], [0.002, 0.0025], M["line"],
              off=0.004, sub=1)
        brow = [(-0.034, 0.056), (0.004, 0.069), (0.042, 0.072)]
        hline("Brow_" + sn, phi, th, [(s * q, y) for q, y in brow], [0.0045, 0.004, 0.002], M["line"], off=0.004)
        decal("Blush_" + sn, s * 38, -30, 0.022, 0.011, make_or_get_blush(), off=0.0008, thick=0.002)
    hline("Mouth", 0, -42, [(-0.011, -0.002), (0, 0.003), (0.011, -0.002)], 0.003, M["line"], off=0.003)
    # 额头十字纹章
    decal("Sigil_V", 0, 27, 0.0042, 0.022, M["sigil"], off=0.002, thick=0.003, group="Face")
    decal("Sigil_H", 0, 27, 0.014, 0.004, M["sigil"], off=0.002, thick=0.003, dy=0.005)
    for dx, dy, w, h in ((0, 0.026, 0.006, 0.007), (0, -0.024, 0.005, 0.006), (-0.017, 0.005, 0.005, 0.006),
                         (0.017, 0.005, 0.005, 0.006)):
        decal("Sigil_Tip", 0, 27, w, h, M["sigil"], off=0.002, thick=0.003, dx=dx, dy=dy, segs=4, rings=2, flat=True)
    for sx in (-1, 1):
        hline("Sigil_Wing", 0, 27, [(sx * 0.006, -0.008), (sx * 0.015, -0.014), (sx * 0.02, -0.006)],
              [0.002, 0.0025, 0.0], M["sigil"], off=0.003)


_BLUSH = []


def make_or_get_blush():
    if not _BLUSH:
        _BLUSH.append(make_mat("M_Blush", "#FFB0A4", 0.6))
    return _BLUSH[0]


def build_hair():
    g = "Hair"
    # 头发壳：比头大一圈，挖掉脸和额头中分的三角
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=36, v_segments=20, radius=1.0)
    dead = []
    for v in bm.verts:
        x, y, z = v.co
        face = y < -0.22 and z < 0.34
        part = y < 0 and z < 0.74 and abs(x) < 0.30 * (0.74 - z) / 0.40 + 0.015
        if face or part or z < -0.78:
            dead.append(v)
    bmesh.ops.delete(bm, geom=dead, context="VERTS")
    for v in bm.verts:
        v.co = HC + Vector((v.co.x * HR.x, v.co.y * HR.y, v.co.z * HR.z)) * 1.035 + Vector((0, 0.004, 0.002))
    finish("HairCap", bm, M["hair_dark"], g)

    # 刘海：贴着头皮从头顶往下扇开
    bangs = [  # phi0, phi1, theta_end, 半宽, 材质, 末端外翘
        (7, 21, 17, 0.034, "hair_dark", 1.09), (26, 40, 6, 0.04, "hair_red", 1.10),
        (44, 57, -4, 0.042, "hair_dark", 1.10), (62, 74, -22, 0.04, "hair_red", 1.12),
        (84, 92, -34, 0.04, "hair_dark", 1.10), (16, 30, 24, 0.028, "hair_red", 1.07),
    ]
    for s in (-1, 1):
        for i, (p0, p1, te, w, mk, lift) in enumerate(bangs):
            pts, nrm, rw, rt = [], [], [], []
            steps = 7
            for k in range(steps + 1):
                f = k / steps
                phi = s * (p0 + (p1 - p0) * f ** 0.8)
                th = 84 + (te - 84) * f
                sc = 1.055 + (lift - 1.055) * f ** 2
                pts.append(hpt(phi, th, sc))
                nrm.append(hframe(phi, th)[2])
                prof = math.sin(math.pi * min(1.0, f * 1.15 + 0.12)) ** 0.7 if f < 0.99 else 0.0
                rw.append(w * prof)
                rt.append(0.013 * (prof ** 0.5))
            tube("Bang_%s%d" % ("L" if s > 0 else "R", i), pts, rt, rw, mat=M[mk], group=g, sides=8,
                 normals=nrm, sub=2)
        # 鬓发：脸侧垂到肩
        for i, (px, py, zend, mk, r) in enumerate(((0.178, -0.085, 0.47, "hair_red", 0.024),
                                                   (0.196, -0.035, 0.43, "hair_dark", 0.028))):
            top = hpt(s * (68 + i * 16), 8, 1.06)
            pts = [top, Vector((s * (px + 0.012), py, 0.69)), Vector((s * px, py - 0.01, 0.60)),
                   Vector((s * (px - 0.012), py, 0.53)), Vector((s * (px + 0.01), py - 0.012, zend))]
            tube("Sidelock_%s%d" % ("L" if s > 0 else "R", i), pts, [r * 0.5, r * 0.6, r * 0.55, r * 0.45, 0.0],
                 [r * 0.9, r, r * 0.9, r * 0.7, 0.0], mat=M[mk], group=g, sides=8, up=Y, sub=3)
    # 后颈垂发
    for i, (phi, x, zend, mk) in enumerate(((180, 0.0, 0.47, "hair_dark"), (150, 0.07, 0.50, "hair_red"),
                                            (210, -0.07, 0.50, "hair_red"), (125, 0.13, 0.53, "hair_dark"),
                                            (235, -0.13, 0.53, "hair_dark"))):
        top = hpt(phi, -15, 1.03)
        pts = [top, Vector((x * 1.05, 0.19, 0.62)), Vector((x, 0.175, 0.55)), Vector((x * 1.1, 0.19, zend))]
        tube("NapeLock_%d" % i, pts, [0.02, 0.024, 0.02, 0.0], [0.045, 0.05, 0.04, 0.0], mat=M[mk], group=g,
             sides=8, up=Y, sub=3)

    # 双马尾
    for s in (-1, 1):
        sn = "L" if s > 0 else "R"
        d = Vector((s * 0.55, 0.16, 0.82)).normalized()
        S = HC + Vector((d.x * HR.x, d.y * HR.y, d.z * HR.z)) * 1.03
        B = S + d * 0.055
        ellipsoid("PonyBun_" + sn, B, (0.06, 0.058, 0.055), M["hair_dark"], g, segs=14, rings=10)
        # 金发箍 + 红宝石 + 小冠尖
        ring("PonyRing_" + sn, S + d * 0.012, d, 0.047, 0.012, M["gold"], "Outfit", sides=8, segs=20)
        gem_dir = (Vector((0, -1, 0.25)) - d * Vector((0, -1, 0.25)).dot(d)).normalized()
        ellipsoid("PonyGem_" + sn, S + d * 0.012 + gem_dir * 0.052, (0.014, 0.014, 0.018), M["gem"], "Outfit",
                  basis=(d.cross(gem_dir), gem_dir, d), segs=6, rings=4, flat=True)
        side = d.cross(gem_dir)
        for k, (a, ln) in enumerate(((-0.9, 0.05), (0.0, 0.075), (0.9, 0.05))):
            base = S + d * 0.02 + (gem_dir * math.cos(a) + side * math.sin(a)) * 0.05
            tube("PonyCrown_%s%d" % (sn, k), [base, base + d * ln + (gem_dir * math.cos(a) + side * math.sin(a)) * 0.012],
                 [0.012, 0.0], [0.006, 0.0], mat=M["gold"], group="Outfit", sides=6, normals=gem_dir)
        # 顶上炸开的短毛
        for k in range(6):
            a = TAU * k / 6 + 0.4
            dd = (d * 0.75 + (gem_dir * math.cos(a) + side * math.sin(a)) * 0.75 + Vector((s * 0.25, 0, 0))).normalized()
            ln = 0.10 + 0.04 * random.random()
            pts = [B, B + dd * ln * 0.55 + Z * 0.025, B + dd * ln + Vector((s * 0.03, 0.01, -0.012))]
            tube("PonyTuft_%s%d" % (sn, k), pts, [0.03, 0.026, 0.0], mat=M["hair_red" if k % 2 else "hair_dark"],
                 group=g, sides=8, up=Y, sub=3)
        # 长卷发束
        locks = [  # ox, oy, zend, rmax, 材质
            (0.00, 0.00, 0.17, 0.062, "hair_dark"), (0.07, -0.05, 0.24, 0.055, "hair_red"),
            (0.08, 0.06, 0.20, 0.058, "hair_dark"), (-0.05, 0.07, 0.27, 0.052, "hair_red"),
            (-0.04, -0.06, 0.31, 0.046, "hair_dark"), (0.14, 0.01, 0.30, 0.05, "hair_red"),
            (0.03, 0.12, 0.25, 0.05, "hair_red"), (-0.09, 0.02, 0.40, 0.04, "hair_dark"),
        ]
        mult = [0.5, 0.65, 0.85, 1.0, 1.0, 0.96, 0.86, 0.7, 0.45, 0.0]
        for k, (ox, oy, zend, rmax, mk) in enumerate(locks):
            ph = random.random() * TAU
            pts = [B, B + Vector((s * 0.075, 0.04, 0.065)), Vector((s * (0.25 + ox * 0.5), 0.12 + oy * 0.5, 0.86))]
            nseg = 7
            for q in range(1, nseg + 1):
                f = q / nseg
                amp = 0.012 + 0.04 * f
                pts.append(Vector((s * (0.27 + ox + 0.05 * f + amp * math.sin(ph + f * 7.0)),
                                   0.15 + oy + 0.7 * amp * math.cos(ph + f * 7.0),
                                   0.86 - (0.86 - zend) * f)))
            pts[-1] += Vector((s * 0.045, 0.0, 0.03))
            tube("PonyLock_%s%d" % (sn, k), pts, [rmax * 0.8 * m for m in mult], [rmax * m for m in mult],
                 mat=M[mk], group=g, sides=8, up=Y, sub=2)


def build_outfit():
    g = "Outfit"
    # 上身黑色抹胸 + 金边 + 胸口宝石
    tube("Bodice", [(0, 0, 0.395), (0, 0, 0.43), (0, 0, 0.465), (0, 0, 0.497)],
         [0.068, 0.066, 0.071, 0.066], [0.083, 0.081, 0.091, 0.088], mat=M["black"], group=g, sides=18,
         normals=Y, sub=3, cap=(True, False))
    ring("BodiceTrim", (0, 0, 0.497), Z, 0.089, 0.006, M["gold"], g, ry=0.067, u=X)
    ellipsoid("ChestGem", (0, -0.071, 0.475), (0.011, 0.006, 0.015), M["gem"], g, segs=6, rings=4, flat=True)
    tube("BodiceStripe", [(0, -0.069, 0.495), (0, -0.068, 0.45), (0, -0.07, 0.41)], 0.003, 0.009, mat=M["gold"],
         group=g, sides=6, normals=Y)
    # 颈环
    ring("Choker", (0, 0, 0.555), Z, 0.03, 0.006, M["gold"], g, u=X, segs=16)
    ellipsoid("ChokerGem", (0, -0.032, 0.553), (0.008, 0.005, 0.01), M["gem"], g, segs=6, rings=4, flat=True)

    # 白色羽毛围领：两层尖瓣绕胸口和上臂
    def petals(tag, count, z, rx, ry, length, drop, width, phase):
        for i in range(count):
            a = TAU * (i + phase) / count
            jit = 0.8 + 0.4 * random.random()
            dirv = Vector((math.sin(a), -math.cos(a) * 0.85, 0)).normalized()
            base = Vector((math.sin(a) * rx, -math.cos(a) * ry, z))
            tipv = base + dirv * length * jit + Z * drop * jit
            mid = base.lerp(tipv, 0.5) + dirv * 0.012 + Z * 0.012
            nrm = (dirv.cross(Z)).cross(tipv - base).normalized()
            tube("%s_%02d" % (tag, i), [base - dirv * 0.012, mid, tipv], [0.012, 0.011, 0.0],
                 [width * 0.7, width, 0.0], mat=M["fur"], group=g, sides=6, normals=nrm, sub=2)

    petals("FurA", 22, 0.478, 0.118, 0.076, 0.085, -0.055, 0.025, 0.0)
    petals("FurB", 20, 0.492, 0.112, 0.074, 0.075, -0.012, 0.023, 0.5)
    petals("FurC", 16, 0.505, 0.100, 0.068, 0.055, 0.03, 0.02, 0.25)

    # 腰带、红腰封、正面金环
    tube("Sash", [(0, 0, 0.385), (0, 0, 0.415)], 0.073, 0.089, mat=M["red"], group=g, sides=18, normals=Y,
         cap=(False, False))
    ring("Belt", (0, 0, 0.412), Z, 0.092, 0.009, M["gold"], g, ry=0.076, u=X)
    ring("BeltLow", (0, 0, 0.386), Z, 0.091, 0.005, M["gold"], g, ry=0.075, u=X)
    ring("BeltRing", (0, -0.088, 0.392), Y, 0.024, 0.006, M["gold"], g, segs=16)
    ellipsoid("BeltGem", (0, -0.086, 0.392), (0.009, 0.006, 0.009), M["gem"], g, segs=6, rings=4, flat=True)

    # 红色内裙：前短，褶 + 锯齿下摆
    def skirt_rf(a, f):
        return 1.0 + 0.045 * math.cos(a * 10) * f

    def skirt_zf(a, f):
        back = 0.5 - 0.5 * math.cos(a)  # 0 前 1 后
        return (-0.035 * (1 - tri(a / TAU * 10)) - 0.05 * back) * f * f

    _, hem, _, _ = lathe("Skirt", [(0.086, 0.405), (0.118, 0.36), (0.152, 0.30), (0.172, 0.265)], M["red"], g,
                         segs=50, rf=skirt_rf, zf=skirt_zf, ry=0.9)
    tube("SkirtTrim", hem, 0.0045, mat=M["gold"], group=g, sides=5, closed=True)
    lathe("SkirtLining", [(0.08, 0.40), (0.11, 0.35), (0.14, 0.30), (0.155, 0.275)], M["deep_red"], g, segs=40,
          ry=0.9)

    # 黑色外袍下摆：正面开衩，后面拖长，金边
    def coat_zf(a, f):
        back = 0.5 - 0.5 * math.cos(a)
        return (-0.045 * (1 - tri((a - math.radians(48)) / math.radians(264) * 5)) - 0.03 * back) * f * f

    def coat_rf(a, f):
        return 1.0 + 0.03 * math.cos(a * 7) * f

    _, hem, c0, c1 = lathe("Coat", [(0.094, 0.41), (0.135, 0.34), (0.185, 0.24), (0.222, 0.15)], M["black"], g,
                           segs=56, a0=math.radians(48), a1=math.radians(312), rf=coat_rf, zf=coat_zf, ry=0.92)
    tube("CoatTrimHem", hem, 0.006, mat=M["gold"], group=g, sides=5)
    tube("CoatTrimL", c0, 0.006, mat=M["gold"], group=g, sides=5)
    tube("CoatTrimR", c1, 0.006, mat=M["gold"], group=g, sides=5)
    lathe("CoatLining", [(0.088, 0.405), (0.127, 0.338), (0.175, 0.243), (0.208, 0.162)], M["deep_red"], g, segs=56,
          a0=math.radians(49), a1=math.radians(311), rf=coat_rf, zf=lambda a, f: coat_zf(a, f) * 0.9, ry=0.92)
    tassel("CoatTasselL", c0[-1] - Z * 0.012, 0.06)
    tassel("CoatTasselR", c1[-1] - Z * 0.012, 0.06)
    # 外袍后背菱形纹
    u = Vector((0, -0.42, 0.9)).normalized()
    n = Vector((0, 0.9, 0.42)).normalized()
    c = Vector((0, 0.158, 0.26)) + n * 0.004
    ellipsoid("CoatEmblem", c, (0.03, 0.05, 0.004), M["gold"], g, basis=(X, u, n), segs=4, rings=2, flat=True)
    ellipsoid("CoatEmblemIn", c + n * 0.002, (0.018, 0.032, 0.004), M["red"], g, basis=(X, u, n), segs=4,
              rings=2, flat=True)

    # 正面垂片（红底金边金菱形）
    tab = [(0, -0.09, 0.40), (0, -0.134, 0.345), (0, -0.166, 0.285), (0, -0.184, 0.225)]
    tube("TabardTrim", tab, 0.005, [0.045, 0.058, 0.052, 0.0], mat=M["gold"], group=g, sides=8, normals=Y, sub=3)
    tube("Tabard", [Vector(p) + Vector((0, -0.003, 0.004)) for p in tab], 0.005, [0.038, 0.05, 0.043, 0.0],
         mat=M["red"], group=g, sides=8, normals=Y, sub=3)
    tu = Vector((0, -0.45, 0.89)).normalized()
    tn = Vector((0, -0.89, -0.45)).normalized()
    ellipsoid("TabardEmblem", Vector((0, -0.150, 0.315)) + tn * 0.012, (0.02, 0.03, 0.004), M["gold"], g,
              basis=(X, tu, tn), segs=4, rings=2, flat=True)

    for s in (-1, 1):
        sn = "L" if s > 0 else "R"
        # 广袖：上沿贴手臂，下沿垂下去
        r_h = [0.04, 0.05, 0.062, 0.072]
        r_v = [0.042, 0.062, 0.088, 0.112]
        axis = [Vector((s * 0.122, 0, 0.478)), Vector((s * 0.162, 0, 0.432)), Vector((s * 0.202, -0.012, 0.394)),
                Vector((s * 0.228, -0.018, 0.37))]
        pts = [p - Z * (rv - 0.04) * 0.75 for p, rv in zip(axis, r_v)]
        tube("Sleeve_" + sn, pts, r_v, r_h, mat=M["black"], group=g, sides=16, sub=3)
        t = (pts[-1] - pts[-2]).normalized()
        n1 = (Z - t * Z.dot(t)).normalized()
        ring("SleeveTrim_" + sn, pts[-1], t, r_v[-1], 0.007, M["gold"], g, ry=r_h[-1], u=n1, segs=28)
        ellipsoid("SleeveLining_" + sn, pts[-1] + t * 0.001, (r_v[-1] * 0.93, r_h[-1] * 0.93, 0.004), M["red"], g,
                  basis=(n1, t.cross(n1), t), segs=20, rings=6)
        t0 = (pts[1] - pts[0]).normalized()
        n0 = (Z - t0 * Z.dot(t0)).normalized()
        ring("SleeveTop_" + sn, pts[0], t0, r_v[0], 0.006, M["gold"], g, ry=r_h[0], u=n0, segs=20)
        tassel("SleeveTassel_" + sn, pts[-1] - n1 * (r_v[-1] + 0.012), 0.065)
        ring("Bracelet_" + sn, (s * 0.243, -0.022, 0.357), t, 0.024, 0.005, M["gold"], g, segs=14)

        # 靴子：黑靴筒、金靴口、金鞋尖、细跟
        x = s * 0.066
        tube("Boot_" + sn, [(x, 0, 0.195), (x, 0, 0.12), (x, 0.004, 0.05), (x, 0.0, 0.03)],
             [0.052, 0.046, 0.042, 0.04], [0.05, 0.044, 0.04, 0.04], mat=M["black"], group=g, sides=14, normals=Y,
             sub=2)
        ellipsoid("Foot_" + sn, (x, -0.034, 0.034), (0.042, 0.076, 0.034), M["black"], g, segs=16, rings=10)
        ellipsoid("ToeCap_" + sn, (x, -0.078, 0.03), (0.034, 0.036, 0.028), M["gold"], g, segs=12, rings=8)
        tube("Heel_" + sn, [(x, 0.03, 0.05), (x, 0.036, 0.0)], [0.02, 0.012], mat=M["black"], group=g, sides=8,
             normals=Y)
        ring("BootCuff_" + sn, (x, 0, 0.195), Z, 0.054, 0.009, M["gold"], g, u=X, segs=18)
        tube("BootCuffPeak_" + sn, [(x, -0.05, 0.197), (x, -0.058, 0.235)], [0.004, 0.0], [0.022, 0.0],
             mat=M["gold"], group=g, sides=6, normals=Y)
        ellipsoid("BootGem_" + sn, (x, -0.056, 0.196), (0.011, 0.006, 0.014), M["gem"], g, segs=6, rings=4,
                  flat=True)
        ring("AnkleBand_" + sn, (x, 0.003, 0.072), Z, 0.043, 0.005, M["gold"], g, u=X, segs=16)


def build_lantern():
    g = "Lantern"
    hx, hy = 0.262, -0.052  # 握杆位置（左手）
    lx, ly, top = 0.385, -0.085, 0.70  # 灯笼挂点
    # 金钩杆：手里一截直杆，顶端弯成卷钩
    staff = [(hx, hy, 0.27), (hx, hy, 0.45), (hx, hy - 0.004, 0.62), (hx + 0.012, hy - 0.01, 0.72),
             (hx + 0.05, hy - 0.02, 0.785), (lx - 0.01, ly + 0.01, 0.80), (lx + 0.022, ly, 0.765),
             (lx + 0.012, ly, 0.728), (lx - 0.012, ly, 0.725), (lx - 0.018, ly, 0.748), (lx - 0.004, ly, 0.758)]
    tube("LanternStaff", staff, [0.009, 0.009, 0.009, 0.0085, 0.008, 0.0075, 0.007, 0.0065, 0.006, 0.005, 0.003],
         mat=M["gold"], group=g, sides=8, up=Y, sub=4)
    ellipsoid("StaffPommel", (hx, hy, 0.268), (0.014, 0.014, 0.016), M["gold"], g, segs=10, rings=8)
    ring("StaffGrip", (hx, hy, 0.375), Z, 0.011, 0.004, M["gold"], g, u=X, segs=12)
    # 挂环 + 短链
    ring("LanternLoop", (lx, ly, top + 0.012), Y, 0.012, 0.0035, M["gold"], g, segs=14)
    c = Vector((lx, ly, 0))

    def lat(name, prof, mat, segs=20):
        ob, *_ = lathe(name, prof, mat, g, segs=segs, psub=2)
        ob.location = c
        return ob

    lat("LanternCap", [(0.004, top), (0.016, top - 0.008), (0.022, top - 0.028), (0.05, top - 0.04),
                       (0.058, top - 0.05), (0.046, top - 0.056), (0.0, top - 0.056)], M["gold"])
    gz = top - 0.118
    ellipsoid("LanternGlobe", (lx, ly, gz), (0.055, 0.055, 0.066), M["glow"], g, segs=20, rings=12)
    for k in range(6):
        a = TAU * k / 6 + TAU / 12
        d = Vector((math.sin(a), -math.cos(a), 0))
        pts = [Vector((lx, ly, gz)) + d * (0.057 * math.cos(t)) + Z * (0.068 * math.sin(t))
               for t in (-1.25, -0.8, -0.3, 0.3, 0.8, 1.25)]
        tube("LanternRib_%d" % k, pts, 0.0045, mat=M["gold"], group=g, sides=5, normals=d, sub=2)
    ring("LanternBand", (lx, ly, gz), Z, 0.057, 0.004, M["gold"], g, u=X, segs=20)
    # 发光十字（正反两面）
    for sy in (-1, 1):
        yy = ly + sy * 0.054
        ellipsoid("LanternCrossV", (lx, yy, gz), (0.006, 0.006, 0.034), M["cross"], g, segs=8, rings=6)
        ellipsoid("LanternCrossH", (lx, yy, gz + 0.008), (0.022, 0.006, 0.006), M["cross"], g, segs=8, rings=6)
        for dx, dz in ((0, 0.036), (0, -0.036), (0.024, 0.008), (-0.024, 0.008)):
            ellipsoid("LanternCrossTip", (lx + dx, yy, gz + dz), (0.007, 0.004, 0.008), M["cross"], g, segs=4,
                      rings=2, flat=True)
    bz = gz - 0.066
    lat("LanternBase", [(0.0, bz + 0.006), (0.046, bz + 0.006), (0.054, bz), (0.036, bz - 0.014),
                        (0.016, bz - 0.022), (0.008, bz - 0.034), (0.0, bz - 0.036)], M["gold"])
    ellipsoid("LanternBead", (lx, ly, bz - 0.046), (0.012, 0.012, 0.012), M["gold"], g, segs=10, rings=8)
    tassel("LanternTassel", (lx, ly, bz - 0.068), 0.1, 0.02, group=g)


# ----------------------------------------------------------------------------
# 合并、预览、导出
# ----------------------------------------------------------------------------
def join_group(key, name):
    objs = GROUPS.get(key, [])
    if not objs:
        return None
    for ob in objs:  # lathe 部件用过 location，先烘进顶点
        if ob.location.length > 0:
            ob.data.transform(ob.matrix_basis)
            ob.matrix_basis.identity()
    bpy.ops.object.select_all(action="DESELECT")
    for ob in objs:
        ob.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = name
    ob.data.name = name
    return ob


def setup_render():
    sc = bpy.context.scene
    for eng in ("BLENDER_EEVEE", "BLENDER_EEVEE_NEXT"):
        try:
            sc.render.engine = eng
            break
        except TypeError:
            continue
    sc.render.resolution_x, sc.render.resolution_y = 880, 1000
    sc.render.image_settings.file_format = "PNG"
    sc.view_settings.view_transform = "Standard"
    world = bpy.data.worlds.new("PreviewWorld")
    world.use_nodes = True
    bg = next(n for n in world.node_tree.nodes if n.type == "BACKGROUND")
    bg.inputs[0].default_value = (0.16, 0.14, 0.15, 1)
    bg.inputs[1].default_value = 1.6
    sc.world = world
    pres = bpy.data.collections.new("Presentation")
    sc.collection.children.link(pres)
    for name, energy, rot in (("KeySun", 3.2, (0.9, 0.0, -0.5)), ("FillSun", 1.2, (1.1, 0.0, 0.9)),
                              ("RimSun", 2.0, (-1.0, 0.0, 2.9))):
        li = bpy.data.lights.new(name, "SUN")
        li.energy = energy
        ob = bpy.data.objects.new(name, li)
        ob.rotation_euler = rot
        pres.objects.link(ob)
    cam = bpy.data.cameras.new("PreviewCam")
    cam.type = "ORTHO"
    cam.ortho_scale = 1.42
    cam_ob = bpy.data.objects.new("PreviewCam", cam)
    pres.objects.link(cam_ob)
    sc.camera = cam_ob
    return cam_ob


def render_views(cam_ob):
    sc = bpy.context.scene
    target = Vector((0.03, 0.02, 0.55))
    views = {"front": (0, -6, 0), "three_quarter": (3.4, -4.6, 0.9), "side": (6, 0, 0), "back": (0, 6, 0),
             "hero": (-2.6, -5.0, 1.4)}
    os.makedirs(os.path.join(OUT_DIR, "previews"), exist_ok=True)
    for name, off in views.items():
        cam_ob.location = target + Vector(off)
        cam_ob.rotation_euler = (target - cam_ob.location).to_track_quat("-Z", "Y").to_euler()
        sc.render.filepath = os.path.join(OUT_DIR, "previews", name + ".png")
        bpy.ops.render.render(write_still=True)


def main():
    global M
    bpy.ops.wm.read_factory_settings(use_empty=True)
    M = build_materials()
    build_body()
    build_face()
    build_hair()
    build_outfit()
    build_lantern()

    char = bpy.data.collections.new("Lantern_RedOrder")
    bpy.context.scene.collection.children.link(char)
    parts = []
    for key, name in (("Body", "Lantern_Body"), ("Face", "Lantern_Face"), ("Hair", "Lantern_Hair"),
                      ("Outfit", "Lantern_Outfit"), ("Lantern", "Lantern_Prop")):
        ob = join_group(key, name)
        bpy.context.scene.collection.objects.unlink(ob)
        char.objects.link(ob)
        parts.append(ob)

    stats = {}
    for ob in parts:
        ob.data.calc_loop_triangles()
        stats[ob.name] = (len(ob.data.vertices), len(ob.data.loop_triangles))
    lo = Vector((min(v.co[i] for ob in parts for v in ob.data.vertices) for i in range(3)))
    hi = Vector((max(v.co[i] for ob in parts for v in ob.data.vertices) for i in range(3)))

    cam_ob = setup_render()
    blend = os.path.join(OUT_DIR, "lantern_red_order.blend")
    bpy.ops.wm.save_as_mainfile(filepath=blend)
    if DO_RENDER:
        render_views(cam_ob)

    bpy.ops.object.select_all(action="DESELECT")
    for ob in parts:
        ob.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    glb = os.path.join(OUT_DIR, "lantern_red_order.glb")
    bpy.ops.export_scene.gltf(filepath=glb, export_format="GLB", use_selection=True, export_cameras=False,
                              export_lights=False, export_apply=True)

    print("== LANTERN BUILD ==")
    for k, (v, t) in stats.items():
        print("  %-16s verts %6d  tris %6d" % (k, v, t))
    print("  TOTAL            verts %6d  tris %6d" % (sum(v for v, _ in stats.values()),
                                                        sum(t for _, t in stats.values())))
    print("  bounds min %s max %s" % (tuple(round(c, 3) for c in lo), tuple(round(c, 3) for c in hi)))
    print("  glb bytes %d" % os.path.getsize(glb))


M = {}
main()
