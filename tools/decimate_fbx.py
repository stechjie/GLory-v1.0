# Blender 无头减面。用法：
#   blender --background --python tools/decimate_fbx.py -- <in.fbx> <out.fbx> <目标顶点数>
#
# formation_ally_4/5 的网格是 44 万 / 68 万顶点，而全项目其余 76 个角色平均 1.7 万。
# 同屏可以有二三十个单位，这两个各自顶得上四十个别的角色。这里把它们压到和其余
# 角色一个量级。
#
# 用 Decimate(COLLAPSE) 而不是重拓扑：COLLAPSE 会按比例插值顶点组权重，蒙皮和骨架
# 绑定能跟着走，而重拓扑要重新刷权重，不是脚本能兜住的事。

import bpy
import sys


def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def total_verts():
    return sum(len(o.data.vertices) for o in bpy.data.objects if o.type == "MESH")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:]
    src, dst, target = argv[0], argv[1], int(argv[2])

    clear_scene()
    bpy.ops.import_scene.fbx(filepath=src)

    before = total_verts()
    if before == 0:
        print("DECIMATE_RESULT fail no_mesh")
        return

    ratio = min(1.0, float(target) / float(before))
    for obj in [o for o in bpy.data.objects if o.type == "MESH"]:
        mod = obj.modifiers.new(name="Decimate", type="DECIMATE")
        mod.decimate_type = "COLLAPSE"
        mod.ratio = ratio
        # 不保留三角形边界会让 UV 缝合处裂开，这批模型是单张贴图整体展开的，必须开。
        mod.use_collapse_triangulate = False
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.modifier_apply(modifier=mod.name)

    after = total_verts()

    # Blender 默认按场景帧范围（1-250）烘焙动画，会把一条 1.2 秒的动作拉成 10.4 秒。
    # 导出前把场景帧范围对齐到实际动作的范围。
    frame_start, frame_end = None, None
    for action in bpy.data.actions:
        a_start, a_end = action.frame_range
        frame_start = a_start if frame_start is None else min(frame_start, a_start)
        frame_end = a_end if frame_end is None else max(frame_end, a_end)
    if frame_start is not None:
        bpy.context.scene.frame_start = int(round(frame_start))
        bpy.context.scene.frame_end = int(round(frame_end))

    # 材质在游戏里被 body_material.tres 整个盖掉，从来不用。但 Blender 会把它们
    # 重新导出成 Image_0.jpg 这类相对引用，而那些文件并不存在——正是先前 13 个空
    # .fbm 目录导致 6 个 FBX 加载失败的同一类死依赖。直接清空材质槽，不留隐患。
    for obj in [o for o in bpy.data.objects if o.type == "MESH"]:
        obj.data.materials.clear()

    bpy.ops.export_scene.fbx(
        filepath=dst,
        use_selection=False,
        apply_unit_scale=True,
        apply_scale_options="FBX_SCALE_NONE",
        object_types={"ARMATURE", "MESH"},
        use_mesh_modifiers=True,
        add_leaf_bones=False,
        bake_anim=True,
        bake_anim_use_all_bones=True,
        bake_anim_use_nla_strips=False,
        bake_anim_use_all_actions=False,
        bake_anim_force_startend_keying=True,
        path_mode="AUTO",
    )
    print("DECIMATE_RESULT ok %d %d %.4f" % (before, after, ratio))


main()
