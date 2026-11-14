"""把一块 AI 生成的毛团外壳（尾巴等）换成 BA 式的大块光滑发束。

blender -b --python tools/ba_parts/fur_clumps.py -- <in.glb> <out_dir> [--clumps 9] [--rings 14]

做法（全部自动）：
  1. 按位置焊接找连通块，取面数第二大的块当尾巴（第一大是身体）。
  2. 从贴身体的一端做测地距离，分段求截面中心线 + 椭圆截面（主/次半径）。
  3. 沿中心线在椭圆周围摆 N 束发束：水滴形截面、发根粗、发梢尖，末端略外翻。
     再加一根细一点的芯，防止发束之间露缝。
  4. 每束 UV：u 横跨 0..1，v 发根 0 -> 发梢 1（给 Shader 算发丝线和高光方向）。
  5. 顶点色取原外壳最近点的贴图色，再压成两色（橙 / 奶白）平涂。
  6. 骨骼权重从原外壳最近面转移，删掉原外壳，导出 GLB（骨架和动画保留）。
"""
import bpy, bmesh, sys, math, heapq, collections, os, random
from mathutils import Vector
from mathutils.kdtree import KDTree
from mathutils.bvhtree import BVHTree
from mathutils.geometry import barycentric_transform

argv = sys.argv[sys.argv.index("--") + 1:]
SRC, OUT = argv[0], argv[1]


def opt(name, default, cast=float):
    return cast(argv[argv.index(name) + 1]) if name in argv else default


N_CLUMPS = opt("--clumps", 9, int)
N_RINGS = opt("--rings", 14, int)
RING_V = 6
os.makedirs(OUT, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)
arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
ob = max((o for o in bpy.data.objects if o.type == 'MESH'), key=lambda o: len(o.data.vertices))
for o in list(bpy.data.objects):
    if o.type == 'MESH' and o is not ob:
        bpy.data.objects.remove(o)   # glTF 导入时附带的骨骼显示球
me = ob.data
img = next(n.image for n in me.materials[0].node_tree.nodes if n.type == 'TEX_IMAGE')
W, H = img.size
PX = list(img.pixels)


def sample(uv):
    x = min(W - 1, max(0, int(uv.x % 1.0 * W)))
    y = min(H - 1, max(0, int(uv.y % 1.0 * H)))
    i = (y * W + x) * 4
    return Vector(PX[i:i + 3])


def luma(c):
    return c.x * 0.3 + c.y * 0.59 + c.z * 0.11


# ---------- 1. 连通块 ----------
bm = bmesh.new()
bm.from_mesh(me)
bm.verts.ensure_lookup_table()
bm.faces.ensure_lookup_table()
uvl = bm.loops.layers.uv.active


def key(v):
    return tuple(round(c, 5) for c in v.co)


parent = {}


def find(a):
    while parent.setdefault(a, a) != a:
        parent[a] = parent[parent[a]]
        a = parent[a]
    return a


for f in bm.faces:
    ks = [key(v) for v in f.verts]
    for k in ks[1:]:
        ra, rb = find(ks[0]), find(k)
        if ra != rb:
            parent[ra] = rb
comps = collections.defaultdict(list)
for f in bm.faces:
    comps[find(key(f.verts[0]))].append(f.index)
order = sorted(comps.values(), key=len, reverse=True)
body_faces, tail_faces = set(order[0]), set(order[1])
tail_verts = sorted({v.index for fi in tail_faces for v in bm.faces[fi].verts})
body_verts = sorted({v.index for fi in body_faces for v in bm.faces[fi].verts})
print("TAIL faces", len(tail_faces), "verts", len(tail_verts))

# ---------- 2. 中心线 ----------
kd_body = KDTree(len(body_verts))
for i, vi in enumerate(body_verts):
    kd_body.insert(bm.verts[vi].co, i)
kd_body.balance()
pos_id = {}
pts = []
for vi in tail_verts:
    k = key(bm.verts[vi])
    if k not in pos_id:
        pos_id[k] = len(pts)
        pts.append(bm.verts[vi].co.copy())
adj = collections.defaultdict(set)
for fi in tail_faces:
    ids = [pos_id[key(v)] for v in bm.faces[fi].verts]
    for a in ids:
        for b in ids:
            if a != b:
                adj[a].add(b)
dbody = [kd_body.find(p)[2] for p in pts]
dmin = min(dbody)
roots = [i for i, d in enumerate(dbody) if d <= dmin + 0.04]
dist = [math.inf] * len(pts)
hq = []
for r in roots:
    dist[r] = 0.0
    heapq.heappush(hq, (0.0, r))
while hq:
    d, a = heapq.heappop(hq)
    if d > dist[a]:
        continue
    for b in adj[a]:
        nd = d + (pts[a] - pts[b]).length
        if nd < dist[b]:
            dist[b] = nd
            heapq.heappush(hq, (nd, b))
dmax = max(d for d in dist if d < math.inf)
NB = 18
bins = [[] for _ in range(NB)]
for i, d in enumerate(dist):
    if d < math.inf:
        bins[min(NB - 1, int(d / dmax * NB))].append(pts[i])
binpts = [b for b in bins if b]
cent = [sum(b, Vector()) / len(b) for b in binpts]
for _ in range(2):
    cent = [cent[0]] + [(cent[i - 1] + cent[i] * 2 + cent[i + 1]) / 4 for i in range(1, len(cent) - 1)] + [cent[-1]]
secs = []
for i, c in enumerate(cent):
    t = (cent[min(i + 1, len(cent) - 1)] - cent[max(i - 1, 0)]).normalized()
    ref = Vector((0, 0, 1)) if abs(t.z) < 0.9 else Vector((1, 0, 0))
    e1 = t.cross(ref).normalized()
    e2 = t.cross(e1)
    P = [((p - c).dot(e1), (p - c).dot(e2)) for p in binpts[i]]
    sxx = sum(x * x for x, y in P) / len(P)
    syy = sum(y * y for x, y in P) / len(P)
    sxy = sum(x * y for x, y in P) / len(P)
    ang = 0.5 * math.atan2(2 * sxy, sxx - syy)
    a = (e1 * math.cos(ang) + e2 * math.sin(ang)).normalized()
    b = t.cross(a).normalized()
    pa = sorted(abs((p - c).dot(a)) for p in binpts[i])
    pb = sorted(abs((p - c).dot(b)) for p in binpts[i])
    ra = pa[int(len(pa) * 0.85)]
    rb = pb[int(len(pb) * 0.85)]
    secs.append([c, t, a, b, max(ra, 0.01), max(rb, 0.01)])
for i in range(1, len(secs)):
    if secs[i][2].dot(secs[i - 1][2]) < 0:
        secs[i][2] = -secs[i][2]
    if secs[i][3].dot(secs[i - 1][3]) < 0:
        secs[i][3] = -secs[i][3]
# 根部往身体里多伸一点，免得露根
c0, t0 = secs[0][0], secs[0][1]
secs.insert(0, [c0 - t0 * secs[0][4] * 0.6, t0, secs[0][2], secs[0][3], secs[0][4] * 0.8, secs[0][5] * 0.8])
for s in secs:
    print("SEC c=(%.2f %.2f %.2f) ra=%.3f rb=%.3f" % (s[0].x, s[0].y, s[0].z, s[4], s[5]))


def sec_at(s):
    """s in [0, 1+]：在截面序列上插值，>1 沿末端切线外推"""
    n = len(secs) - 1
    if s >= 1.0:
        c, t, a, b, ra, rb = secs[-1]
        return [c + t * (s - 1.0) * (ra + rb) * 2.0, t, a, b, ra, rb]
    f = s * n
    i = int(f)
    w = f - i
    A, B = secs[i], secs[min(i + 1, n)]
    return [A[0].lerp(B[0], w), A[1].lerp(B[1], w).normalized(), A[2].lerp(B[2], w).normalized(),
            A[3].lerp(B[3], w).normalized(), A[4] * (1 - w) + B[4] * w, A[5] * (1 - w) + B[5] * w]


# ---------- 3. 发束 ----------
random.seed(7)
verts, faces, uvs, strand_of = [], [], [], []


def add_strand(sid, path_fn, width_fn, thick_fn, side_fn, normal_fn, rings=N_RINGS):
    base = len(verts)
    for r in range(rings + 1):
        v = r / rings
        c, side, nrm = path_fn(v), side_fn(v), normal_fn(v)
        w, th = width_fn(v), thick_fn(v)
        for k in range(RING_V):
            ang = 2 * math.pi * k / RING_V
            x = math.cos(ang) * w
            y = math.sin(ang) * th * (1.0 if math.sin(ang) > 0 else 0.55)   # 水滴形：外鼓内平
            verts.append(c + side * x + nrm * y)
            uvs.append((k / RING_V, v))
            strand_of.append(sid)
    for r in range(rings):
        for k in range(RING_V):
            a = base + r * RING_V + k
            b = base + r * RING_V + (k + 1) % RING_V
            faces.append((a, b, b + RING_V, a + RING_V))
    tip = len(verts)
    verts.append(path_fn(1.0) + (path_fn(1.0) - path_fn(0.95)) * 0.6)
    uvs.append((0.5, 1.0))
    strand_of.append(sid)
    last = base + rings * RING_V
    for k in range(RING_V):
        faces.append((last + k, last + (k + 1) % RING_V, tip))


def taper(v, tip_start=0.6):
    rise = min(1.0, 0.55 + v * 3.0)
    fall = 1.0 if v < tip_start else max(0.0, 1.0 - ((v - tip_start) / (1 - tip_start)) ** 1.4)
    return rise * fall


for k in range(N_CLUMPS):
    th0 = 2 * math.pi * (k + 0.5) / N_CLUMPS + random.uniform(-0.12, 0.12)
    s_end = 1.0 + random.uniform(-0.10, 0.22)
    flare = random.uniform(0.15, 0.45)

    def frame(v, th0=th0, s_end=s_end):
        return sec_at(v * s_end)

    def path(v, th0=th0, flare=flare, frame=frame):
        c, t, a, b, ra, rb = frame(v)
        off = 0.52 + flare * max(0.0, v - 0.7) / 0.3 * 0.6
        return c + (a * math.cos(th0) * ra + b * math.sin(th0) * rb) * off

    def side(v, th0=th0, frame=frame):
        c, t, a, b, ra, rb = frame(v)
        return (-a * math.sin(th0) * ra + b * math.cos(th0) * rb).normalized()

    def nrm(v, th0=th0, frame=frame):
        c, t, a, b, ra, rb = frame(v)
        return (a * math.cos(th0) * rb + b * math.sin(th0) * ra).normalized()

    def width(v, s_end=s_end):
        c, t, a, b, ra, rb = sec_at(min(v * s_end, 1.0))
        return math.pi * (ra + rb) / N_CLUMPS * 0.95 * taper(v)

    def thick(v, s_end=s_end):
        c, t, a, b, ra, rb = sec_at(min(v * s_end, 1.0))
        return min(ra, rb) * 0.55 * taper(v)

    add_strand(k, path, width, thick, side, nrm)

add_strand(N_CLUMPS, lambda v: sec_at(v * 0.92)[0],
           lambda v: sec_at(v * 0.92)[4] * 0.62 * taper(v, 0.5),
           lambda v: sec_at(v * 0.92)[5] * 0.62 * taper(v, 0.5),
           lambda v: sec_at(v * 0.92)[2], lambda v: sec_at(v * 0.92)[3])
print("CLUMP verts", len(verts), "faces", len(faces))

# ---------- 4/5. 新网格 + 顶点色 ----------
tail_bm = bmesh.new()
vmap = {}
for fi in tail_faces:
    for v in bm.faces[fi].verts:
        if v.index not in vmap:
            vmap[v.index] = tail_bm.verts.new(v.co)
tail_uv = tail_bm.loops.layers.uv.new()
for fi in tail_faces:
    f = bm.faces[fi]
    nf = tail_bm.faces.new([vmap[v.index] for v in f.verts])
    for l, nl in zip(f.loops, nf.loops):
        nl[tail_uv].uv = l[uvl].uv
tail_bm.faces.ensure_lookup_table()
bvh = BVHTree.FromBMesh(tail_bm)

cm = bpy.data.meshes.new("fur_clumps")
cm.from_pydata([tuple(v) for v in verts], [], faces)
cm.update()
uvlay = cm.uv_layers.new(name="UVMap")
for poly in cm.polygons:
    for li in poly.loop_indices:
        uvlay.data[li].uv = uvs[cm.loops[li].vertex_index]
cols = []
for p in verts:
    loc, n, fi, d = bvh.find_nearest(p)
    f = tail_bm.faces[fi]
    co = [l.vert.co for l in f.loops][:3]
    uv3 = [Vector((l[tail_uv].uv.x, l[tail_uv].uv.y, 0)) for l in f.loops][:3]
    uvp = barycentric_transform(loc, co[0], co[1], co[2], uv3[0], uv3[1], uv3[2])
    cols.append(sample(Vector((uvp.x, uvp.y))))
ls = sorted(luma(c) for c in cols)
thr = ls[len(ls) // 2]


def med(cs):
    return Vector([sorted(c[i] for c in cs)[len(cs) // 2] for i in range(3)])


CREAM = med([c for c in cols if luma(c) >= thr])
ORANGE = med([c for c in cols if luma(c) < thr])
print("PALETTE cream", tuple(round(x, 3) for x in CREAM), "orange", tuple(round(x, 3) for x in ORANGE))
ca = cm.color_attributes.new("Color", 'FLOAT_COLOR', 'POINT')
for i, c in enumerate(cols):
    p = CREAM if luma(c) >= thr else ORANGE
    ca.data[i].color = (p.x, p.y, p.z, 1.0)

clumps = bpy.data.objects.new("fur_clumps", cm)
bpy.context.collection.objects.link(clumps)
clumps.parent = arm
clumps.matrix_world = ob.matrix_world.copy()
for p in cm.polygons:
    p.use_smooth = True

# ---------- 6. 权重转移 ----------
tail_me = bpy.data.meshes.new("tail_src")
tail_bm.to_mesh(tail_me)
src = bpy.data.objects.new("tail_src", tail_me)
bpy.context.collection.objects.link(src)
src.matrix_world = ob.matrix_world.copy()
for vi_old, nv in vmap.items():
    for g in me.vertices[vi_old].groups:
        name = ob.vertex_groups[g.group].name
        vg = src.vertex_groups.get(name) or src.vertex_groups.new(name=name)
        vg.add([nv.index], g.weight, 'REPLACE')
for g in ob.vertex_groups:
    if g.name not in clumps.vertex_groups:
        clumps.vertex_groups.new(name=g.name)
mod = clumps.modifiers.new("dt", 'DATA_TRANSFER')
mod.object = src
mod.use_vert_data = True
mod.data_types_verts = {'VGROUP_WEIGHTS'}
mod.vert_mapping = 'POLYINTERP_NEAREST'
mod.layers_vgroup_select_src = 'ALL'
mod.layers_vgroup_select_dst = 'NAME'
bpy.context.view_layer.objects.active = clumps
bpy.ops.object.modifier_apply(modifier="dt")
am = clumps.modifiers.new("Armature", 'ARMATURE')
am.object = arm

bm2 = bmesh.new()
bm2.from_mesh(me)
bm2.faces.ensure_lookup_table()
bmesh.ops.delete(bm2, geom=[bm2.faces[i] for i in tail_faces], context='FACES')
bmesh.ops.delete(bm2, geom=[v for v in bm2.verts if not v.link_faces], context='VERTS')
bm2.to_mesh(me)
me.update()
bpy.data.objects.remove(src)

mat = bpy.data.materials.new("fur_clumps")
mat.use_nodes = True
nt = mat.node_tree
bsdf = nt.nodes["Principled BSDF"]
vc = nt.nodes.new("ShaderNodeVertexColor")
vc.layer_name = "Color"
nt.links.new(vc.outputs["Color"], bsdf.inputs["Base Color"])
cm.materials.append(mat)

base = os.path.splitext(os.path.basename(SRC))[0]
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, base + "_clumps.blend"))
bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, base + "_clumps.glb"), export_format='GLB',
                          export_vertex_color='ACTIVE', export_animations=True, export_tangents=True)
print("SAVED", os.path.join(OUT, base + "_clumps.glb"))
