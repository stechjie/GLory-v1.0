"""松鼠 v2 组装：身体 + 4 件装备 + 脸部贴片 -> 一个 GLB（静态，未绑骨）。

blender -b --python tools/ba_parts/assemble_squirrel.py -- <parts_dir> <gpt_dir> <out.glb>

位置都从 GPT 正面图（body_front.png）上量的像素坐标换算到模型坐标：
Pixal3D 用这张图做正面，模型包围盒 x/z 对应图里 alpha 包围盒的 x/y。
这些像素坐标是这只松鼠专用的（第一只先手量），以后要改成自动找关键点。
"""
import bpy, bmesh, sys, os, math
from mathutils import Vector, Matrix

argv = sys.argv[sys.argv.index("--") + 1:]
PARTS, GPT, OUT = argv[0], argv[1], argv[2]

# ---- body_front.png 上量的像素 ----
IMG_X0, IMG_X1, IMG_Y0, IMG_Y1 = 124, 986, 62, 1185   # alpha 包围盒
CENTER_X = 686.5                                       # 两眼中点（身体中线）
CHIN_Y, SHOULDER_Y, WAIST_Y = 715, 790, 960
NECK_HALF, WAIST_HALF = 170, 191                       # 不含尾巴的半宽（像素）
PAW_R = (468, 885)                                     # 角色右手（图左）
# 脸贴片：decal 像素 -> 正面图像素 的相似变换（两眼中心对齐）
DECAL_C, FRONT_C, DECAL_S = (626.5, 535.0), (686.5, 523.5), 241.0 / 561.0

bpy.ops.wm.read_factory_settings(use_empty=True)


def load(path, name):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = [o for o in bpy.data.objects if o not in before]
    ob = next(o for o in new if o.type == 'MESH')
    for o in new:
        if o is not ob:
            bpy.data.objects.remove(o)
    ob.name = name
    ob.parent = None
    # GLB 里嵌的是烘焙原图；换成磁盘上补过洞的 _basecolor.png（fill_bake_holes.py）
    png = path[:-4] + "_basecolor.png"
    if os.path.exists(png):
        img = bpy.data.images.load(png)
        for m in ob.data.materials:
            for n in (m.node_tree.nodes if m and m.node_tree else []):
                if n.type == 'TEX_IMAGE':
                    n.image = img
    return ob


body = load(os.path.join(PARTS, "body_low.glb"), "body")
bw = [body.matrix_world @ v.co for v in body.data.vertices]
lo = Vector([min(p[i] for p in bw) for i in range(3)])
hi = Vector([max(p[i] for p in bw) for i in range(3)])
H = hi.z - lo.z
print("body bbox", tuple(round(c, 3) for c in lo), tuple(round(c, 3) for c in hi))
px = (hi.x - lo.x) / (IMG_X1 - IMG_X0)     # 每像素对应的模型长度（x）
pz = H / (IMG_Y1 - IMG_Y0)


def X(ix):
    return lo.x + (ix - IMG_X0) * px


def Z(iy):
    return hi.z - (iy - IMG_Y0) * pz


def slab(iy, half_px):
    """某高度、身体中线附近（不含尾巴）的前后范围"""
    z, xc, hw = Z(iy), X(CENTER_X), half_px * px
    ys = sorted(p.y for p in bw if abs(p.z - z) < H * 0.015 and abs(p.x - xc) < hw * 0.6)
    # 尾巴贴在背后：从前往后找第一个大空档，空档之后算尾巴
    back = ys[-1]
    for a, b in zip(ys, ys[1:]):
        if b - a > H * 0.02 and a - ys[0] > hw * 0.8:
            back = a
            break
    return ys[0], back


def place(path, name, width=None, height=None, center=None, top=None, front=None, back=None, rot=(0, 0, 0)):
    """front / back：让配件的最前面（min y）或最后面（max y）贴到这个 y 上，覆盖 center.y"""
    ob = load(path, name)
    ob.rotation_euler = [math.radians(a) for a in rot]
    bpy.context.view_layer.update()
    for o in bpy.data.objects:
        o.select_set(o is ob)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    ps = [v.co for v in ob.data.vertices]
    a = Vector([min(p[i] for p in ps) for i in range(3)])
    b = Vector([max(p[i] for p in ps) for i in range(3)])
    s = (width / (b.x - a.x)) if width else (height / (b.z - a.z))
    c = (a + b) / 2
    for v in ob.data.vertices:
        v.co = (v.co - c) * s
    half_h = (b.z - a.z) * s / 2
    if top is not None:
        center = Vector((top.x, top.y, top.z - half_h))
    center = center.copy()
    if front is not None:
        center.y = front + (b.y - a.y) * s / 2
    if back is not None:
        center.y = back - (b.y - a.y) * s / 2
    ob.location = center
    print("placed", name, "scale %.3f" % s, "at", tuple(round(x, 3) for x in center))
    return ob


xc = X(CENTER_X)
# 围巾：上沿贴下巴，套在脖子中心
f, k = slab(CHIN_Y + 40, NECK_HALF)
print("neck slab", round(f, 3), round(k, 3))
# 叶子往下垂到胸口，胸口比脖子更靠前：取围巾覆盖高度内身体最靠前的点
chest_front = min(slab(y, NECK_HALF)[0] for y in range(CHIN_Y + 20, CHIN_Y + 181, 20))
print("chest front", round(chest_front, 3))
scarf = place(os.path.join(PARTS, "acc_0_low.glb"), "acc_scarf", width=NECK_HALF * 2 * px * 1.3,
              top=Vector((xc, 0, Z(CHIN_Y - 5))), front=chest_front - H * 0.015)
# 腰带：挂件朝前，前沿略出肚皮
f, k = slab(WAIST_Y, WAIST_HALF)
print("waist slab", round(f, 3), round(k, 3))
belt = place(os.path.join(PARTS, "acc_2_low.glb"), "acc_belt", width=WAIST_HALF * 2 * px * 1.1,
             center=Vector((xc, 0, Z(WAIST_Y))), front=f - H * 0.02)
# 卷轴：横背在肩后，夹在背和尾巴之间
f, k = slab(SHOULDER_Y + 30, NECK_HALF)
print("shoulder slab", round(f, 3), round(k, 3))
scroll = place(os.path.join(PARTS, "acc_1_low.glb"), "acc_scroll", width=NECK_HALF * 2 * px * 1.2,
               center=Vector((xc, 0, Z(SHOULDER_Y))), front=k - H * 0.02)
# 灯笼：提手挂在右爪
pzr = Z(PAW_R[1])
pxr = X(PAW_R[0])
near = [p.y for p in bw if abs(p.z - pzr) < H * 0.03 and abs(p.x - pxr) < H * 0.03]
pyr = min(near) if near else (lo.y + hi.y) / 2
lantern = place(os.path.join(PARTS, "acc_3_low.glb"), "acc_lantern", height=H * 0.2,
                top=Vector((pxr, pyr, pzr + H * 0.02)))

# ---- 脸部贴片 ----
bm = bmesh.new()
bm.from_mesh(body.data)
bm.faces.ensure_lookup_table()
mw = body.matrix_world


def front_px(p):
    return (IMG_X0 + (p.x - lo.x) / px, IMG_Y0 + (hi.z - p.z) / pz)


def decal_uv(p):
    fx, fy = front_px(p)
    dx = (fx - FRONT_C[0]) / DECAL_S + DECAL_C[0]
    dy = (fy - FRONT_C[1]) / DECAL_S + DECAL_C[1]
    return dx / 1254.0, 1.0 - dy / 1254.0


keep = []
for fc in bm.faces:
    n = (mw.to_3x3() @ fc.normal).normalized()
    if n.y > -0.25:      # 只要朝前的面（glTF 前方 = Blender -Y）
        continue
    us = [decal_uv(mw @ v.co) for v in fc.verts]
    if all(0.08 < u < 0.92 and 0.36 < w < 0.70 for u, w in us):
        keep.append(fc.index)
dbm = bmesh.new()
vm = {}
uvl = dbm.loops.layers.uv.new("UVMap")
for fi in keep:
    fc = bm.faces[fi]
    vs = []
    for v in fc.verts:
        if v.index not in vm:
            p = mw @ v.co
            vm[v.index] = dbm.verts.new(p + (mw.to_3x3() @ v.normal).normalized() * H * 0.003)
        vs.append(vm[v.index])
    nf = dbm.faces.new(vs)
    for l in nf.loops:
        l[uvl].uv = decal_uv(l.vert.co)
dme = bpy.data.meshes.new("face_decal")
dbm.to_mesh(dme)
decal = bpy.data.objects.new("face_decal", dme)
bpy.context.collection.objects.link(decal)
for p in dme.polygons:
    p.use_smooth = True
mat = bpy.data.materials.new("face_decal")
nt = mat.node_tree
t = nt.nodes.new("ShaderNodeTexImage")
t.image = bpy.data.images.load(os.path.join(GPT, "face_decal_rgba.png"))
t.extension = 'CLIP'
bs = nt.nodes["Principled BSDF"]
nt.links.new(t.outputs["Color"], bs.inputs["Base Color"])
nt.links.new(t.outputs["Alpha"], bs.inputs["Alpha"])
mat.blend_method = 'CLIP' if hasattr(mat, "blend_method") else None
mat.surface_render_method = 'DITHERED'
dme.materials.append(mat)
print("decal faces", len(keep))

for o in bpy.data.objects:
    o.select_set(o.type == 'MESH')
bpy.ops.export_scene.gltf(filepath=OUT, export_format='GLB', use_selection=True)
bpy.ops.wm.save_as_mainfile(filepath=os.path.splitext(OUT)[0] + ".blend")
print("SAVED", OUT)
