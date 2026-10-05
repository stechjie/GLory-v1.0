"""Decimate the skinned meshes of one crimson GLB in Blender and dump the geometry.

blender --background --factory-startup --python tools/model_refinement/crimson_decimate.py -- \
    --glb <original.glb> --out <dump.npz> [--target <mesh_index>:<vertices> ...]

Only geometry leaves this script: per glTF mesh, positions and the original (custom) normals
in Blender world space (glTF axes), UV0 and the four strongest joint weights, plus the
UNDECIMATED positions/UVs as a reference. Blender's frame is not trusted: the importer stores
skinned meshes relative to the armature and guesses bind poses (armbreaker's maul moved), so
crimson_refine.py fits the Blender -> glTF mapping on the reference by matching UVs. Normals are not recomputed:
merging by position joins the two layers of double-sided hair cards, and smoothing those
averages front and back into garbage. crimson_refine.py writes them into
a copy of the ORIGINAL GLB, so nodes, skins and animations are never re-exported by
Blender. A mesh without --target is dumped undecimated (used to check the round trip).
"Vertices" means glTF vertices (split at UV seams), the number Godot and
model_asset_budget_check count.
"""
import argparse
import json
import struct
import sys

import bpy
import numpy as np


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--glb", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--target", action="append", default=[], help="<mesh index>:<glTF vertex count>")
    return parser.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])


def mesh_objects(glb):
    """Imported mesh objects keyed by glTF mesh index; the importer names mesh data after the glTF mesh."""
    data = open(glb, "rb").read()
    names = [m["name"] for m in json.loads(data[20:20 + struct.unpack_from("<I", data, 12)[0]])["meshes"]]
    if len(set(names)) != len(names):
        raise RuntimeError(f"duplicate glTF mesh names {names}")
    by_name = {obj.data.name: obj for obj in bpy.context.scene.objects if obj.type == "MESH"}
    missing = [n for n in names if n not in by_name]
    if missing or len(by_name) != len(names):
        raise RuntimeError(f"mesh objects {sorted(by_name)} do not match glTF meshes {names}")
    return {i: by_name[n] for i, n in enumerate(names)}


def evaluated(obj, ratio):
    """Mesh of obj after an optional collapse decimation (armature deformation removed)."""
    for mod in list(obj.modifiers):
        obj.modifiers.remove(mod)
    if ratio < 1.0:
        mod = obj.modifiers.new("Decimate", "DECIMATE")
        mod.decimate_type = "COLLAPSE"
        mod.ratio = ratio
        mod.use_collapse_triangulate = True
    depsgraph = bpy.context.evaluated_depsgraph_get()
    return obj.evaluated_get(depsgraph).to_mesh()


def split_vertices(mesh):
    """glTF vertices: one per distinct (vertex, UV, normal) corner."""
    mesh.calc_loop_triangles()
    uv = mesh.uv_layers.active.data
    tris = mesh.loop_triangles
    loops = np.empty(len(tris) * 3, dtype=np.int64)
    tris.foreach_get("loops", loops)
    vert_of_loop = np.empty(len(mesh.loops), dtype=np.int64)
    mesh.loops.foreach_get("vertex_index", vert_of_loop)
    uvs = np.empty(len(mesh.loops) * 2, dtype=np.float32)
    uv.foreach_get("uv", uvs)
    uvs = uvs.reshape(-1, 2)
    normals = np.array([n.vector for n in mesh.corner_normals], dtype=np.float64)
    corner_vert = vert_of_loop[loops]
    keys = np.column_stack([corner_vert.astype(np.float64), np.round(uvs[loops].astype(np.float64), 6),
                            np.round(normals[loops], 3)])
    unique, first, inverse = np.unique(keys, axis=0, return_index=True, return_inverse=True)
    # Columns: vertex, u, v, then the exact (unrounded) corner normal of the first corner.
    return np.column_stack([unique[:, :3], normals[loops][first]]), inverse.reshape(-1)


def world_positions(obj, mesh, vert):
    co = np.empty(len(mesh.vertices) * 3, dtype=np.float32)
    mesh.vertices.foreach_get("co", co)
    world = np.array(obj.matrix_world, dtype=np.float64)
    return co.reshape(-1, 3)[vert].astype(np.float64) @ world[:3, :3].T + world[:3, 3], world


# Blender (x, -z, y) -> glTF (x, y, z); the importer flips V.
def to_gltf(a):
    return np.column_stack([a[:, 0], a[:, 2], -a[:, 1]])


def gltf_uv(unique):
    uv = unique[:, 1:3].astype(np.float32)
    uv[:, 1] = 1.0 - uv[:, 1]
    return uv


def reference(obj, mesh):
    unique, _ = split_vertices(mesh)
    co, _ = world_positions(obj, mesh, unique[:, 0].astype(np.int64))
    return {"ref_positions": to_gltf(co), "ref_uv": gltf_uv(unique)}


def dump(obj, mesh, joint_names):
    unique, indices = split_vertices(mesh)
    vert = unique[:, 0].astype(np.int64)
    co, world = world_positions(obj, mesh, vert)
    normals = unique[:, 3:6] @ np.linalg.inv(world[:3, :3])
    normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-12)
    groups = {g.index: g.name for g in obj.vertex_groups}
    order = {name: i for i, name in enumerate(joint_names)}
    joints = np.zeros((len(vert), 4), dtype=np.uint16)
    weights = np.zeros((len(vert), 4), dtype=np.float32)
    for row, v in enumerate(vert):
        pairs = sorted(((g.weight, order[groups[g.group]]) for g in mesh.vertices[v].groups if g.weight > 0.0), reverse=True)[:4]
        total = sum(w for w, _ in pairs)
        if total <= 0.0:
            raise RuntimeError(f"{obj.name}: vertex {v} has no joint weight")
        for k, (w, j) in enumerate(pairs):
            joints[row, k], weights[row, k] = j, w / total
    return {"positions": to_gltf(co), "normals": to_gltf(normals), "uv": gltf_uv(unique),
            "joints": joints, "weights": weights, "indices": indices.astype(np.uint32)}


def main():
    args = parse_args()
    targets = {int(k): int(v) for k, v in (t.split(":") for t in args.target)}
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=args.glb, merge_vertices=True, import_shading="NORMALS", disable_bone_shape=True)
    objects = mesh_objects(args.glb)
    out = {}
    for index, obj in sorted(objects.items()):
        # Shape keys block modifiers; the crimson GLBs carry at most an unused zero-weight key.
        if obj.data.shape_keys is not None:
            obj.shape_key_clear()
        armature = obj.find_armature() or obj.parent
        if armature is None or armature.type != "ARMATURE":
            raise RuntimeError(f"{obj.name}: skinned mesh without an armature")
        # The importer creates one vertex group per skin joint, in skin order.
        joint_names = [g.name for g in obj.vertex_groups]
        ratio, mesh = 1.0, evaluated(obj, 1.0)
        full = len(split_vertices(mesh)[0])
        ref = reference(obj, mesh)
        if index in targets and targets[index] < full:
            lo, hi = 0.02, 1.0
            for _ in range(14):
                ratio = (lo + hi) / 2
                count = len(split_vertices(evaluated(obj, ratio))[0])
                if abs(count - targets[index]) <= targets[index] * 0.01:
                    break
                lo, hi = (ratio, hi) if count < targets[index] else (lo, ratio)
            mesh = evaluated(obj, ratio)
        data = dict(dump(obj, mesh, joint_names), **ref)
        for key, arr in data.items():
            out[f"m{index}_{key}"] = arr
        out[f"m{index}_joint_names"] = np.array(joint_names)
        print(f"CRIMSON_DECIMATE mesh={index} name={obj.name} ratio={ratio:.4f} vertices {full} -> {len(data['positions'])} "
              f"triangles {len(data['indices']) // 3}")
    np.savez_compressed(args.out, **out)
    print(f"CRIMSON_DECIMATE_COMPLETE {args.out}")


main()
