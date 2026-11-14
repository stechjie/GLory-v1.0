"""把原模型（不含尾巴）重建成光滑干净的形体，并把原贴图颜色烘回去。

blender -b --python tools/ba_parts/smooth_rebuild.py -- <orig.glb> <out_dir> [--voxel 120] [--smooth 6] [--tex 1024]

步骤：取最大连通块（身体+装备，尾巴是第二块单独处理）-> 体素重建（高度/voxel）->
平滑 -> 存成 OBJ 交给 simplify.py 减面；同时把原网格（带贴图）存成 glb 当烘焙源。
"""
import bpy, bmesh, sys, os, collections

argv = sys.argv[sys.argv.index("--") + 1:]
SRC, OUT = argv[0], argv[1]
VOX = float(argv[argv.index("--voxel") + 1]) if "--voxel" in argv else 120
SMOOTH = int(argv[argv.index("--smooth") + 1]) if "--smooth" in argv else 6
PART = int(argv[argv.index("--part") + 1]) if "--part" in argv else 0   # 0 = 最大块（身体），1 = 第二块（尾巴）
NAME = "body" if PART == 0 else "part%d" % PART
os.makedirs(OUT, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)
ob = max((o for o in bpy.data.objects if o.type == 'MESH'), key=lambda o: len(o.data.vertices))
for o in list(bpy.data.objects):
    if o is not ob:
        bpy.data.objects.remove(o)
# 去掉骨骼修改器/父子，按静止姿势取几何
ob.parent = None
for m in list(ob.modifiers):
    ob.modifiers.remove(m)
if ob.data.shape_keys:   # 有形态键时修改器不能应用；只要静止形状
    ob.shape_key_clear()
bpy.context.view_layer.objects.active = ob
ob.select_set(True)
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

# 连通块：最大块 = 身体，其余（尾巴）删掉
bm = bmesh.new()
bm.from_mesh(ob.data)
key = lambda v: tuple(round(c, 5) for c in v.co)
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
    comps[find(key(f.verts[0]))].append(f)
order = sorted(comps.values(), key=len, reverse=True)
bmesh.ops.delete(bm, geom=[f for i, c in enumerate(order) if i != PART for f in c], context='FACES')
bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context='VERTS')
bm.to_mesh(ob.data)
ob.data.update()
H = ob.dimensions.z
print("body faces", len(ob.data.polygons), "height", round(H, 3))
# 烘焙源：带原贴图的身体
bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "orig_%s.glb" % NAME), export_format='GLB', use_selection=True)

sm = ob.copy()
sm.data = ob.data.copy()
bpy.context.collection.objects.link(sm)
for o in bpy.data.objects:
    o.select_set(o is sm)
bpy.context.view_layer.objects.active = sm
r = sm.modifiers.new("vox", 'REMESH')
r.mode = 'VOXEL'
r.voxel_size = H / VOX
bpy.ops.object.modifier_apply(modifier="vox")
if SMOOTH:
    s = sm.modifiers.new("sm", 'CORRECTIVE_SMOOTH')
    s.factor = 0.8
    s.iterations = SMOOTH
    s.smooth_type = 'SIMPLE'
    s.use_only_smooth = True
    bpy.ops.object.modifier_apply(modifier="sm")
print("smooth faces", len(sm.data.polygons))
sm.data.materials.clear()
bpy.ops.wm.obj_export(filepath=os.path.join(OUT, "%s_smooth.obj" % NAME), export_selected_objects=True,
                      export_materials=False, export_uv=False, export_normals=False)
print("SAVED")
