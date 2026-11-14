"""快速多视图（Workbench，看形状和平涂色用，不代表最终着色）。

blender -b --python tools/ba_parts/quick_views.py -- <out.png> <a.glb> [<b.glb> ...] [--res 512] [--frame N]
每个 GLB 一行，列 = 正 / 四分之三 / 侧 / 背。
"""
import bpy, sys, math, os
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
res = int(argv[argv.index("--res") + 1]) if "--res" in argv else 512
frame = int(argv[argv.index("--frame") + 1]) if "--frame" in argv else 0
files = [a for a in argv[1:] if a.endswith(".glb")]
OUT = argv[0]
ANGLES = [0, 40, 90, 180]
tmp = os.path.splitext(OUT)[0] + "_cells"
os.makedirs(tmp, exist_ok=True)
cells = []
for fi, path in enumerate(files):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=path)
    for o in list(bpy.data.objects):
        if o.type == 'MESH' and o.name.startswith("Icosphere"):
            bpy.data.objects.remove(o)
    sc = bpy.context.scene
    sc.frame_set(frame)
    sc.render.engine = 'BLENDER_WORKBENCH'
    sc.display.shading.light = 'STUDIO'
    sc.display.shading.color_type = 'TEXTURE'
    sc.display.shading.show_cavity = False
    sc.render.film_transparent = True
    sc.render.resolution_x = sc.render.resolution_y = res
    meshes = [o for o in bpy.data.objects if o.type == 'MESH']
    dg = bpy.context.evaluated_depsgraph_get()
    pts = []
    for o in meshes:
        ev = o.evaluated_get(dg)
        m = ev.to_mesh()
        pts += [ev.matrix_world @ v.co for v in m.vertices]
        ev.to_mesh_clear()
    lo = Vector([min(p[i] for p in pts) for i in range(3)])
    hi = Vector([max(p[i] for p in pts) for i in range(3)])
    ctr = (lo + hi) / 2
    size = max(hi - lo) * 1.1
    # 顶点色材质在 TEXTURE 模式下不显示，换成属性显示
    for o in meshes:
        if o.data.color_attributes and not any(n.type == 'TEX_IMAGE' for m in o.data.materials if m and m.node_tree for n in m.node_tree.nodes):
            o.color = (1, 1, 1, 1)
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = 'ORTHO'
    cam_data.ortho_scale = size
    cam = bpy.data.objects.new("cam", cam_data)
    sc.collection.objects.link(cam)
    sc.camera = cam
    for ci, ang in enumerate(ANGLES):
        a = math.radians(ang)
        d = Vector((math.sin(a), -math.cos(a), 0.15)).normalized()   # glTF 前方 = Blender -Y
        cam.location = ctr + d * size * 3
        cam.rotation_euler = (ctr - cam.location).to_track_quat('-Z', 'Y').to_euler()
        f = os.path.join(tmp, "%d_%d.png" % (fi, ci))
        # 有顶点色的网格用 VERTEX 模式再渲一遍叠上去太麻烦：分两次渲染取并集
        sc.display.shading.color_type = 'TEXTURE'
        sc.render.filepath = f
        bpy.ops.render.render(write_still=True)
        has_vc = any(o.data.color_attributes for o in meshes)
        if has_vc:
            sc.display.shading.color_type = 'VERTEX'
            sc.render.filepath = f.replace(".png", "_vc.png")
            bpy.ops.render.render(write_still=True)
        cells.append((fi, ci, f, has_vc))
# 拼图
import numpy as np
rows, cols = len(files), len(ANGLES)
sheet = np.zeros((rows * res, cols * res, 4), dtype=np.float32)
sheet[..., :3] = 0.3
sheet[..., 3] = 1
for fi, ci, f, has_vc in cells:
    im = bpy.data.images.load(f)
    a = np.array(im.pixels[:], dtype=np.float32).reshape(res, res, 4)
    if has_vc:
        b = np.array(bpy.data.images.load(f.replace(".png", "_vc.png")).pixels[:], dtype=np.float32).reshape(res, res, 4)
        # TEXTURE 模式下无贴图的面是白/灰，VERTEX 模式下有贴图的面是白：
        # 取每个像素里“更不白”的那张
        wa = a[..., :3].min(axis=2); wb = b[..., :3].min(axis=2)
        pick = (wb < wa - 0.02)[..., None]
        a = np.where(pick, b, a)
    y0 = (rows - 1 - fi) * res
    rgb = a[..., :3] * a[..., 3:4] + 0.3 * (1 - a[..., 3:4])
    sheet[y0:y0 + res, ci * res:(ci + 1) * res, :3] = rgb
out = bpy.data.images.new("sheet", cols * res, rows * res, alpha=True)
out.pixels = sheet.ravel()
out.filepath_raw = OUT
out.file_format = 'PNG'
out.save()
print("SHEET", OUT)
