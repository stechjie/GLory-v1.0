"""原模型逐面按贴图颜色聚类，出调试图（每类一种纯色）+ 每类统计。

blender -b --python tools/ba_parts/face_classes.py -- <in.glb> <out_dir> [--k 10]
输出：<out_dir>/face_classes.json（每个面的类号 + 每类平均色/面数/位置），face_classes.glb（按类上色）。
原模型 UV 是上千个碎块，所以按面采样（三个角 + 中心的中位数），不按贴图区域。
"""
import bpy, bmesh, sys, os, json, colorsys, random
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
SRC, OUT = argv[0], argv[1]
K = int(argv[argv.index("--k") + 1]) if "--k" in argv else 10
os.makedirs(OUT, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)
ob = max((o for o in bpy.data.objects if o.type == 'MESH'), key=lambda o: len(o.data.vertices))
me = ob.data
img = next(n.image for n in me.materials[0].node_tree.nodes if n.type == 'TEX_IMAGE')
W, H = img.size
import numpy as np
PX = np.array(img.pixels[:], dtype=np.float32).reshape(H, W, 4)[..., :3]


def srgb_to_lab(c):
    c = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    M = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
    xyz = c @ M.T / np.array([0.9505, 1.0, 1.089])
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


bm = bmesh.new()
bm.from_mesh(me)
bm.faces.ensure_lookup_table()
uvl = bm.loops.layers.uv.active
cols = []
cents = []
for f in bm.faces:
    uvs = [l[uvl].uv for l in f.loops]
    pts = uvs + [sum(uvs, Vector((0, 0))) / len(uvs)]
    # 角点往中心收一点，避开 UV 岛边缘的渗色
    c = pts[-1]
    pts = [p.lerp(c, 0.35) for p in pts[:-1]] + [c]
    s = np.array([PX[min(H - 1, max(0, int(p.y % 1 * H))), min(W - 1, max(0, int(p.x % 1 * W)))] for p in pts])
    cols.append(np.median(s, axis=0))
    cents.append(tuple(ob.matrix_world @ f.calc_center_median()))
cols = np.array(cols)
lab = srgb_to_lab(cols)
# k-means（Lab，L 权重减半，让同色不同明暗归一类）
w = np.array([0.5, 1.0, 1.0])
rng = np.random.default_rng(3)
cent = lab[rng.choice(len(lab), K, replace=False)]
for _ in range(40):
    d = (((lab[:, None, :] - cent[None]) * w) ** 2).sum(-1)
    lbl = d.argmin(1)
    cent = np.array([lab[lbl == k].mean(0) if (lbl == k).any() else cent[k] for k in range(K)])
info = []
P = np.array(cents)
for k in range(K):
    m = lbl == k
    rgb = cols[m].mean(0) if m.any() else np.zeros(3)
    h, s, v = colorsys.rgb_to_hsv(*rgb)
    info.append({"k": k, "faces": int(m.sum()), "rgb": [round(float(x), 3) for x in rgb],
                 "hsv": [round(float(h), 2), round(float(s), 2), round(float(v), 2)],
                 "center": [round(float(x), 3) for x in P[m].mean(0)] if m.any() else None})
    print("CLASS", info[-1])
json.dump({"classes": info, "face_class": lbl.tolist()}, open(os.path.join(OUT, "face_classes.json"), "w"))
# 调试上色：每类一个醒目颜色
pal = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (1, 0, 1), (0, 1, 1), (1, 0.5, 0), (0.5, 0, 1), (0.3, 0.3, 0.3), (1, 1, 1), (0.5, 1, 0.5), (0.6, 0.3, 0.1)]
ca = me.color_attributes.new("cls", 'BYTE_COLOR', 'CORNER')
for poly in me.polygons:
    c = pal[lbl[poly.index] % len(pal)]
    for li in poly.loop_indices:
        ca.data[li].color = (*c, 1)
me.materials.clear()
mat = bpy.data.materials.new("cls")
nt = mat.node_tree
vc = nt.nodes.new("ShaderNodeVertexColor")
vc.layer_name = "cls"
nt.links.new(vc.outputs["Color"], nt.nodes["Principled BSDF"].inputs["Base Color"])
me.materials.append(mat)
for o in list(bpy.data.objects):
    if o.type == 'MESH' and o is not ob:
        bpy.data.objects.remove(o)
bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "face_classes.glb"), export_format='GLB',
                          export_vertex_color='ACTIVE', export_animations=False)
print("SAVED")
