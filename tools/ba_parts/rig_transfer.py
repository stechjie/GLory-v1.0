"""把新部件挂到原模型的骨架上：权重从原网格最近面插值转移，原动画保留。

blender -b --python tools/ba_parts/rig_transfer.py -- <orig.glb> <out.glb> <part1.glb> [<part2.glb> ...]

部件必须和原网格在同一坐标里（smooth_rebuild.py 输出的就是：原网格应用了自身变换、去掉父级后的坐标，
也就是骨架空间）。部件贴图用旁边的 <part>_basecolor.png（fill_bake_holes 补过的）。
"""
import bpy, sys, os

argv = sys.argv[sys.argv.index("--") + 1:]
ORIG, OUT, PARTS = argv[0], argv[1], argv[2:]

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=ORIG)
arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
src = max((o for o in bpy.data.objects if o.type == 'MESH'), key=lambda o: len(o.data.vertices))
for o in list(bpy.data.objects):
    if o.type == 'MESH' and o is not src:
        bpy.data.objects.remove(o)
print("orig parent", src.parent.name if src.parent else None, "basis", [round(x, 3) for x in src.matrix_basis.to_scale()])

# 原网格按连通块拆成两份权重源：最大块（身体）和第二块（尾巴）。
# 不拆的话尾巴新网格会从更近的背部面取权重，动起来跟着身体走、不像原来那样摆。
import bmesh, collections
def component_copy(idx):
    o = src.copy()
    o.data = src.data.copy()
    bpy.context.collection.objects.link(o)
    bm = bmesh.new()
    bm.from_mesh(o.data)
    key = lambda v: tuple(round(c, 5) for c in v.co)
    par = {}
    def find(a):
        while par.setdefault(a, a) != a:
            par[a] = par[par[a]]
            a = par[a]
        return a
    for f in bm.faces:
        ks = [key(v) for v in f.verts]
        for k in ks[1:]:
            ra, rb = find(ks[0]), find(k)
            if ra != rb:
                par[ra] = rb
    comps = collections.defaultdict(list)
    for f in bm.faces:
        comps[find(key(f.verts[0]))].append(f)
    order = sorted(comps.values(), key=len, reverse=True)
    bmesh.ops.delete(bm, geom=[f for i, c in enumerate(order) if i != idx for f in c], context='FACES')
    bm.to_mesh(o.data)
    return o
SRC_BY_PART = {0: component_copy(0), 1: component_copy(1)}

new_objs = []
for path in PARTS:
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    ob = next(o for o in bpy.data.objects if o not in before and o.type == 'MESH')
    for o in bpy.data.objects:
        if o not in before and o is not ob:
            bpy.data.objects.remove(o)
    ob.name = os.path.splitext(os.path.basename(path))[0]
    png = path[:-4] + "_basecolor.png"
    if os.path.exists(png):
        img = bpy.data.images.load(png)
        for m in ob.data.materials:
            for n in (m.node_tree.nodes if m and m.node_tree else []):
                if n.type == 'TEX_IMAGE':
                    n.image = img
    # 部件顶点 = 原网格 matrix_basis 应用后的骨架空间坐标
    ob.parent = arm
    ob.matrix_parent_inverse.identity()
    ob.matrix_basis.identity()
    # glTF 导入会在 UV 接缝处拆开顶点；不合并的话接缝两边权重平滑后不一致，动起来裂开
    bpy.context.view_layer.objects.active = ob
    for o in bpy.data.objects:
        o.select_set(o is ob)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.remove_doubles(threshold=0.0001 * max(ob.dimensions))
    bpy.ops.object.mode_set(mode='OBJECT')
    for g in src.vertex_groups:
        ob.vertex_groups.new(name=g.name)
    dt = ob.modifiers.new("dt", 'DATA_TRANSFER')
    dt.object = SRC_BY_PART[1 if "tail" in ob.name else 0]
    dt.use_object_transform = True
    dt.use_vert_data = True
    dt.data_types_verts = {'VGROUP_WEIGHTS'}
    dt.vert_mapping = 'POLYINTERP_NEAREST'
    dt.layers_vgroup_select_src = 'ALL'
    dt.layers_vgroup_select_dst = 'NAME'
    bpy.context.view_layer.objects.active = ob
    for o in bpy.data.objects:
        o.select_set(o is ob)
    bpy.ops.object.modifier_apply(modifier="dt")
    # 个别顶点会取到和邻居差很多的权重（灯笼/爪子和腿连在一起的地方），动起来被拉成长尖刺；平滑几轮
    bpy.ops.object.mode_set(mode='WEIGHT_PAINT')
    bpy.ops.object.vertex_group_smooth(group_select_mode='ALL', factor=0.5, repeat=3)
    bpy.ops.object.mode_set(mode='OBJECT')
    # 每个顶点最多 4 根骨，归一化
    bpy.ops.object.vertex_group_limit_total(group_select_mode='ALL', limit=4)
    bpy.ops.object.vertex_group_normalize_all(lock_active=False)
    am = ob.modifiers.new("Armature", 'ARMATURE')
    am.object = arm
    new_objs.append(ob)
    print("rigged", ob.name, len(ob.data.vertices))

bpy.data.objects.remove(src)
for o in SRC_BY_PART.values():
    bpy.data.objects.remove(o)
for o in bpy.data.objects:
    o.select_set(True)
bpy.ops.export_scene.gltf(filepath=OUT, export_format='GLB', use_selection=True, export_animations=True)
print("SAVED", OUT)
