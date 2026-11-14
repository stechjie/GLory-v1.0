"""低模展 UV + 从高模烘焙颜色贴图（Blender 后台）。

先减面：D:/Pixal3D/.venv/Scripts/python.exe tools/ba_parts/simplify.py raw.glb low.obj --faces 4000
再烘焙：blender -b --python tools/ba_parts/lowpoly_bake.py -- raw.glb low.obj out.glb [--tex 1024]

Blender 自带 Collapse 在生成器网格上降不下去（见 simplify.py 说明），所以减面不在这里做。
"""
import bpy, sys, os, math

argv = sys.argv[sys.argv.index("--") + 1:]
SRC, LOW_OBJ, OUT = argv[0], argv[1], argv[2]
TEX = int(argv[argv.index("--tex") + 1]) if "--tex" in argv else 1024

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)
meshes = [o for o in bpy.data.objects if o.type == 'MESH']
for o in bpy.data.objects:
    o.select_set(o in meshes)
bpy.context.view_layer.objects.active = meshes[0]
if len(meshes) > 1:
    bpy.ops.object.join()
high = bpy.context.view_layer.objects.active
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
size = max(high.dimensions)
# 烘焙改走 Emission：Diffuse Color 通道在金属面上是黑的（灯笼框架就是这样烘成一片黑）
for m in high.data.materials:
    if not (m and m.node_tree):
        continue
    for n in m.node_tree.nodes:
        if n.type == 'BSDF_PRINCIPLED':
            bc = n.inputs["Base Color"]
            if bc.is_linked:
                m.node_tree.links.new(bc.links[0].from_socket, n.inputs["Emission Color"])
            else:
                n.inputs["Emission Color"].default_value = bc.default_value
            n.inputs["Emission Strength"].default_value = 1.0

before = set(bpy.data.objects)
bpy.ops.wm.obj_import(filepath=LOW_OBJ)   # OBJ 是 Y-up，导入器转成 Z-up，和 glTF 导入一致
low = next(o for o in bpy.data.objects if o not in before)
low.name = "body_low"
for o in bpy.data.objects:
    o.select_set(o is low)
bpy.context.view_layer.objects.active = low
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
print("[bake] high", len(high.data.polygons), "low tris", sum(len(p.vertices) - 2 for p in low.data.polygons))
# 减面后约 16% 的面朝向反了（非流形处 fix_normals 判不对），在游戏 Shader 里会被当背面压暗成棕斑。
# 高模本身的法线也不一致，不能拿来参考。
import bmesh
lb = bmesh.new()
lb.from_mesh(low.data)
lb.faces.ensure_lookup_table()
# 奇偶射线（沿法线数穿过次数）在细毛尖处判不准，试过弃用；用 Blender 的一致化：按连通关系统一绕序，再按体积判断朝外
before = {f.index: f.normal.copy() for f in lb.faces}
bmesh.ops.recalc_face_normals(lb, faces=lb.faces)
flip = [f for f in lb.faces if f.normal.dot(before[f.index]) < 0]
print("[bake] recalc flipped", len(flip))

lb.to_mesh(low.data)
low.data.update()
# OBJ 导入会带回逐面的自定义法线 + 锐边，卡通着色的硬阈值会把每个三角面单独切成亮/暗块。
# 清掉，改成按顶点平滑的法线（BA 也是用平滑法线算明暗）。
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
bpy.ops.mesh.remove_doubles(threshold=size * 1e-5)
bpy.ops.mesh.mark_sharp(clear=True)
bpy.ops.object.mode_set(mode='OBJECT')
if low.data.has_custom_normals:
    bpy.ops.mesh.customdata_custom_splitnormals_clear()
for p in low.data.polygons:
    p.use_smooth = True
for a in ("sharp_edge", "sharp_face"):
    if a in low.data.attributes:
        low.data.attributes.remove(low.data.attributes[a])
# 明暗用的法线：减面后的毛面凹凸太碎，卡通硬阈值会切出一片片阴影斑。
# 复制一份做强力平滑，把它的法线写回原网格当自定义法线（形状不变，只有明暗变顺）。
SMOOTH_IT = int(argv[argv.index("--normal-smooth") + 1]) if "--normal-smooth" in argv else 25
if SMOOTH_IT > 0:
    sm = low.copy()
    sm.data = low.data.copy()
    bpy.context.collection.objects.link(sm)
    mod = sm.modifiers.new("sm", 'SMOOTH')
    mod.factor = 1.0
    mod.iterations = SMOOTH_IT
    bpy.context.view_layer.objects.active = sm
    for o in bpy.data.objects:
        o.select_set(o is sm)
    bpy.ops.object.modifier_apply(modifier="sm")
    dt = low.modifiers.new("nt", 'DATA_TRANSFER')
    dt.object = sm
    dt.use_loop_data = True
    dt.data_types_loops = {'CUSTOM_NORMAL'}
    dt.loop_mapping = 'TOPOLOGY'
    bpy.context.view_layer.objects.active = low
    for o in bpy.data.objects:
        o.select_set(o is low)
    bpy.ops.object.modifier_apply(modifier="nt")
    bpy.data.objects.remove(sm)
    print("[bake] smoothed shading normals, iterations", SMOOTH_IT)
while low.data.uv_layers:
    low.data.uv_layers.remove(low.data.uv_layers[0])
low.data.uv_layers.new(name="UVMap")
low.data.materials.clear()
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
bpy.ops.uv.smart_project(angle_limit=math.radians(80), island_margin=0.0015)
bpy.ops.uv.pack_islands(rotate=True, margin=0.0015)
bpy.ops.object.mode_set(mode='OBJECT')

# 透明底：没被射线命中的像素保持 alpha=0，之后由 fill_bake_holes.py 用最近的有效色补
img = bpy.data.images.new("baked", TEX, TEX, alpha=True)
img.generated_color = (0, 0, 0, 0)
mat = bpy.data.materials.new("baked")
nt = mat.node_tree
tex = nt.nodes.new("ShaderNodeTexImage")
tex.image = img
nt.links.new(tex.outputs["Color"], nt.nodes["Principled BSDF"].inputs["Base Color"])
nt.nodes["Principled BSDF"].inputs["Roughness"].default_value = 1.0
nt.nodes.active = tex
low.data.materials.append(mat)

sc = bpy.context.scene
sc.render.engine = 'CYCLES'
sc.cycles.device = 'CPU'
sc.cycles.samples = 1
bk = sc.render.bake
bk.use_selected_to_active = True
bk.use_cage = False
bk.cage_extrusion = size * 0.02
bk.max_ray_distance = size * 0.05
bk.margin = 0   # 不让 Blender 扩边：它会把岛边缘漏掉的黑像素一起扩出去，每个三角面一圈黑边
for o in bpy.data.objects:
    o.select_set(o in (high, low))
bpy.context.view_layer.objects.active = low
bpy.ops.object.bake(type='EMIT')
png = os.path.splitext(OUT)[0] + "_basecolor.png"
img.filepath_raw = png
img.file_format = 'PNG'
img.save()
for o in list(bpy.data.objects):
    if o is not low:
        bpy.data.objects.remove(o)
low.select_set(True)
bpy.ops.export_scene.gltf(filepath=OUT, export_format='GLB', use_selection=True)
print("[bake] wrote", OUT, png)
