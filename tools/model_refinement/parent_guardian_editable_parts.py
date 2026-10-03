"""Bind editable guardian parts to their original Blender bones, without export.

Run with Blender 4.5.14 --background --python THIS -- --source INPUT.blend
--output guardian_refined_editable.blend --report guardian_editable_check.json.
Only the new blend/report are written. The input blend and runtime GLBs stay intact.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

import bpy
from mathutils import Matrix, Quaternion


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def matrix_rows(matrix):
    return [[float(value) for value in row] for row in matrix]


def matrix_error(left, right):
    return max(abs(left[row][col] - right[row][col]) for row in range(4) for col in range(4))


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def action_signature(action):
    curves = []
    for layer in action.layers:
        for strip in layer.strips:
            for bag in getattr(strip, "channelbags", []):
                for curve in bag.fcurves:
                    curves.append({
                        "path": curve.data_path,
                        "index": curve.array_index,
                        "extrapolation": curve.extrapolation,
                        "keys": [[*point.co, *point.handle_left, *point.handle_right,
                                  point.interpolation, point.handle_left_type,
                                  point.handle_right_type] for point in curve.keyframe_points],
                    })
    return {"name": action.name, "range": list(action.frame_range),
            "curve_count": len(curves), "curves_sha256": fingerprint(curves)}


def rig_signature(rig):
    return {"name": rig.name, "world": matrix_rows(rig.matrix_world),
            "bones": [{"name": bone.name, "parent": bone.parent.name if bone.parent else None,
                       "rest": matrix_rows(bone.matrix_local), "length": bone.length,
                       "deform": bone.use_deform} for bone in rig.data.bones]}


def original_geometry_signature(objects):
    return {obj.name: fingerprint({"vertices": [list(v.co) for v in obj.data.vertices],
                                  "polygons": [list(p.vertices) for p in obj.data.polygons]})
            for obj in objects if obj.type == "MESH" and not obj.get("bone_name")}


args = sys.argv[sys.argv.index("--") + 1:]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", required=True)
parser.add_argument("--output", required=True)
parser.add_argument("--report", required=True)
opts = parser.parse_args(args)
source = Path(opts.source).resolve()
output = Path(opts.output).resolve()
report_path = Path(opts.report).resolve()
assert source != output, "Never overwrite the original authoring source"
assert output.suffix == ".blend" and report_path.suffix == ".json"
source_hash = digest(source)
runtime_source = source.parent / "guardian_armor.glb"
runtime_hash = digest(runtime_source) if runtime_source.exists() else None
bpy.ops.wm.open_mainfile(filepath=str(source))
rigs = [obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"]
assert len(rigs) == 1, "Expected the single original rig"
rig = rigs[0]
parts = sorted([obj for obj in bpy.context.scene.objects if obj.get("bone_name")], key=lambda obj: obj.name)
assert parts, "No editable parts with bone_name were found"
assert all(obj.type == "MESH" for obj in parts)
assert all(obj["bone_name"] in rig.data.bones for obj in parts), "Unknown bone mapping"
assert all(not any(mod.type == "ARMATURE" for mod in obj.modifiers) for obj in parts), "Avoid double deformation"
original_actions = sorted([action_signature(action) for action in bpy.data.actions], key=lambda row: row["name"])
assert {"idle", "run", "attack"}.issubset({action.name for action in bpy.data.actions})
assert all(row["curve_count"] > 0 for row in original_actions), "Animation curves must actually exist"
original_rig = rig_signature(rig)
original_geometry = original_geometry_signature(bpy.context.scene.objects)
original_frame = bpy.context.scene.frame_current
original_subframe = bpy.context.scene.frame_subframe
original_pose_position = rig.data.pose_position
animation_data = rig.animation_data
original_action = animation_data.action if animation_data else None
original_action_name = original_action.name if original_action else None
original_slot = animation_data.action_slot if animation_data else None
original_nla = [(track, track.mute) for track in animation_data.nla_tracks] if animation_data else []
original_pose = {bone.name: (bone.matrix_basis.copy(), bone.rotation_mode) for bone in rig.pose.bones}

# Parent in true REST space. Updating after assigning the BONE parent lets Blender
# account for its bone-tail parent basis; assigning matrix_world afterward keeps
# each authored part in exactly its original character-space placement.
rig.data.pose_position = "REST"
bpy.context.view_layer.update()
rest_world = {obj.name: obj.matrix_world.copy() for obj in parts}
parenting_rows = []
for obj in parts:
    old_parent = obj.parent.name if obj.parent else None
    obj.parent = rig
    obj.parent_type = "BONE"
    obj.parent_bone = obj["bone_name"]
    obj.matrix_parent_inverse = Matrix.Identity(4)
    bpy.context.view_layer.update()
    obj.matrix_world = rest_world[obj.name]
    bpy.context.view_layer.update()
    error = matrix_error(obj.matrix_world, rest_world[obj.name])
    assert error < 1e-5, (obj.name, "rest world drift", error)
    parenting_rows.append({"part": obj.name, "bone": obj.parent_bone,
                           "previous_parent": old_parent, "parent": rig.name,
                           "rest_world_max_error": error,
                           "original_rest_world": matrix_rows(rest_world[obj.name])})

# Temporarily stop only the in-memory animation evaluation, then rotate each
# actual pose bone. Compare each attached part with the measured bone world delta.
if animation_data:
    animation_data.action = None
    for track, _mute in original_nla:
        track.mute = True
for bone in rig.pose.bones:
    bone.matrix_basis = Matrix.Identity(4)
rig.data.pose_position = "POSE"
bpy.context.view_layer.update()
zero_pose = {obj.name: obj.matrix_world.copy() for obj in parts}
assert max(matrix_error(zero_pose[name], rest_world[name]) for name in zero_pose) < 1e-5
rotation_rows = []
for bone_name in sorted({obj["bone_name"] for obj in parts}):
    bone = rig.pose.bones[bone_name]
    old_basis = bone.matrix_basis.copy()
    old_mode = bone.rotation_mode
    before_bone = rig.matrix_world @ bone.matrix
    before_parts = {obj.name: obj.matrix_world.copy() for obj in parts}
    bone.rotation_mode = "QUATERNION"
    bone.rotation_quaternion = Quaternion((1.0, 0.0, 0.0), math.radians(17.0))
    bpy.context.view_layer.update()
    after_bone = rig.matrix_world @ bone.matrix
    delta = after_bone @ before_bone.inverted()
    for obj in parts:
        if obj.parent_bone != bone_name:
            continue
        moved = matrix_error(obj.matrix_world, before_parts[obj.name])
        follow_error = matrix_error(obj.matrix_world, delta @ before_parts[obj.name])
        assert moved > 1e-4, (obj.name, "bone rotation did not move part")
        assert follow_error < 1e-5, (obj.name, "incorrect rigid bone follow", follow_error)
        rotation_rows.append({"part": obj.name, "bone": bone_name,
                              "test_rotation_degrees": 17.0,
                              "world_matrix_change": moved, "bone_delta_max_error": follow_error})
    bone.rotation_mode = old_mode
    bone.matrix_basis = old_basis
    bpy.context.view_layer.update()
    restore_error = max(matrix_error(obj.matrix_world, before_parts[obj.name]) for obj in parts)
    assert restore_error < 1e-5, (bone_name, "pose restore drift", restore_error)

# Restore the incoming editor pose, selected action, NLA mute flags and frame.
for bone in rig.pose.bones:
    matrix, mode = original_pose[bone.name]
    bone.rotation_mode = mode
    bone.matrix_basis = matrix
if animation_data:
    animation_data.action = original_action
    if original_slot:
        animation_data.action_slot = original_slot
    for track, mute in original_nla:
        track.mute = mute
rig.data.pose_position = original_pose_position
bpy.context.scene.frame_set(original_frame, subframe=original_subframe)
bpy.context.view_layer.update()
assert rig_signature(rig) == original_rig
assert original_geometry_signature(bpy.context.scene.objects) == original_geometry
assert sorted([action_signature(action) for action in bpy.data.actions], key=lambda row: row["name"]) == original_actions
output.parent.mkdir(parents=True, exist_ok=True)
bpy.ops.wm.save_as_mainfile(filepath=str(output))

# Reopen the delivered file: validate persistence, rest placement and action data.
bpy.ops.wm.open_mainfile(filepath=str(output))
rig = bpy.data.objects[original_rig["name"]]
saved_pose_position = rig.data.pose_position
rig.data.pose_position = "REST"
bpy.context.view_layer.update()
reopen_errors = []
for row in parenting_rows:
    obj = bpy.data.objects[row["part"]]
    assert obj.parent == rig and obj.parent_type == "BONE" and obj.parent_bone == row["bone"]
    error = matrix_error(obj.matrix_world, Matrix(row["original_rest_world"]))
    assert error < 1e-5
    reopen_errors.append(error)
rig.data.pose_position = saved_pose_position
bpy.context.view_layer.update()
assert rig_signature(rig) == original_rig
assert original_geometry_signature(bpy.context.scene.objects) == original_geometry
assert sorted([action_signature(action) for action in bpy.data.actions], key=lambda row: row["name"]) == original_actions
assert (rig.animation_data.action.name if rig.animation_data.action else None) == original_action_name
assert digest(source) == source_hash
assert runtime_hash is None or digest(runtime_source) == runtime_hash
report = {"status": "PASS", "blender": bpy.app.version_string,
          "source": str(source), "source_sha256": source_hash,
          "output": str(output), "output_sha256": digest(output),
          "script": str(Path(__file__).resolve()),
          "script_sha256": digest(__file__),
          "original_source_unchanged": True, "runtime_glb_unchanged": True,
          "runtime_glb_checked": str(runtime_source), "runtime_glb_sha256": runtime_hash,
          "export_performed": False, "armature_count": len(rigs),
          "armature_name": rig.name, "blender_bone_count": len(rig.data.bones),
          "bone_count_note": "Blender armature data has 82 bones; the imported skeleton root is the RL_BoneRoot armature object. Do not substitute Godot's skeleton count.",
          "part_count": len(parenting_rows), "target_bone_count": len({row['bone'] for row in parenting_rows}),
          "actions": original_actions, "active_action_restored": rig.animation_data.action.name,
          "frame_restored": bpy.context.scene.frame_current,
          "rig_rest_and_hierarchy_unchanged": True, "original_geometry_unchanged": True,
          "animation_keyframes_unchanged": True,
          "max_rest_world_error": max(row["rest_world_max_error"] for row in parenting_rows),
          "max_bone_follow_error": max(row["bone_delta_max_error"] for row in rotation_rows),
          "max_reopen_rest_world_error": max(reopen_errors),
          "parenting": parenting_rows, "actual_bone_rotation_checks": rotation_rows,
          "scope": "Editable DCC source parenting only; no runtime model export or visual/performance acceptance."}
report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf8")
print("GUARDIAN_EDITABLE_SOURCE_PASS", json.dumps({"parts": len(parenting_rows), "bones": len(rig.data.bones), "output": str(output), "report": str(report_path)}))
