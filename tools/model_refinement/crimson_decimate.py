"""Decimate the skinned meshes of one crimson GLB in Blender and dump the geometry.

blender --background --factory-startup --python tools/model_refinement/crimson_decimate.py -- \
    --glb <original.glb> --out <dump.npz> [--target <mesh_index>:<vertices> ...]

Only geometry leaves this script: positions, surface normals, UVs and skin weights,
plus an undecimated position/UV reference for the bind-frame fit in crimson_refine.py.
Coincident UV/normal seam vertices with matching skin weights MUST be welded before
collapse decimation. The old per-corner topology let faces collapse independently,
opening thousands of cracks in clothing. UVs remain per corner; animation is never
re-exported. --repack-uv bakes the same albedo onto connected charts to reduce the
runtime UV seam vertex count without cutting more holes to reach the budget.
"Vertices" means glTF vertices (split at UV seams), the number Godot and
model_asset_budget_check count.
"""
import argparse
import json
import struct
import sys

import bpy
import bmesh
from collections import defaultdict
from pathlib import Path
import numpy as np


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--glb", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--target", action="append", default=[], help="<mesh index>:<glTF vertex count>")
    parser.add_argument("--repack-uv", action="store_true", help="Bake 1024px albedo onto new UV charts; discard old tangent-space normal maps")
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
        mod.vertex_group = "_PreserveExtrema"
        mod.invert_vertex_group = True
        mod.vertex_group_factor = 1.0
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
        pairs = sorted(((g.weight, order[groups[g.group]]) for g in mesh.vertices[v].groups if g.weight > 0.0 and groups[g.group] in order), reverse=True)[:4]
        total = sum(w for w, _ in pairs)
        if total <= 0.0:
            raise RuntimeError(f"{obj.name}: vertex {v} has no joint weight")
        for k, (w, j) in enumerate(pairs):
            joints[row, k], weights[row, k] = j, w / total
    return {"positions": to_gltf(co), "normals": to_gltf(normals), "uv": gltf_uv(unique),
            "joints": joints, "weights": weights, "indices": indices.astype(np.uint32)}


def prepare_surface(obj):
    """Join only coincident vertices that deform together, keeping corner UVs."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    deform = bm.verts.layers.deform.active
    groups = defaultdict(list)
    for vertex in bm.verts:
        weights = tuple(sorted((j, round(w, 6)) for j, w in vertex[deform].items() if w > 0.0)) if deform else ()
        groups[(tuple(vertex.co), weights)].append(vertex)
    targets = {v: group[0] for group in groups.values() for v in group[1:]}
    before = len(bm.verts)
    bmesh.ops.weld_verts(bm, targetmap=targets)
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()
    # Imported per-triangle custom normals otherwise survive the weld and still
    # shade a connected surface as separate shards.
    obj.data.normals_split_custom_set([(0, 0, 0)] * len(obj.data.loops))
    for polygon in obj.data.polygons:
        polygon.use_smooth = True
    print(f"CRIMSON_WELD {obj.name}: {before} -> {len(obj.data.vertices)} vertices")


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
        prepare_surface(obj)
        # Preserve the original silhouette bounds (notably Icey's long hair).
        coordinates = np.array([v.co for v in obj.data.vertices])
        extrema = set(np.argmin(coordinates, axis=0)) | set(np.argmax(coordinates, axis=0))
        protect = obj.vertex_groups.new(name="_PreserveExtrema")
        protect.add([int(i) for i in extrema], 1.0, 'REPLACE')
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
        if args.repack_uv:
            # Bake the evaluated surface onto connected UV charts. Keep the original
            # reference UVs for crimson_refine's bind-frame fit.
            bake_obj = bpy.data.objects.new('BakeTarget', mesh.copy())
            bpy.context.collection.objects.link(bake_obj)
            bake_obj.matrix_world = obj.matrix_world.copy()
            for group in obj.vertex_groups: bake_obj.vertex_groups.new(name=group.name)
            bpy.ops.object.select_all(action='DESELECT'); bake_obj.select_set(True); bpy.context.view_layer.objects.active=bake_obj
            source_uv=bake_obj.data.uv_layers.active;source_uv.name='SourceUV'
            new_uv=bake_obj.data.uv_layers.new(name='RuntimeUV');bake_obj.data.uv_layers.active_index=len(bake_obj.data.uv_layers)-1;new_uv.active_render=True
            bpy.ops.object.mode_set(mode='EDIT');bpy.ops.mesh.select_all(action='SELECT');bpy.ops.uv.smart_project(angle_limit=1.50,island_margin=0.003);bpy.ops.object.mode_set(mode='OBJECT')
            image=bpy.data.images.new(f'baked_{index}',width=1024,height=1024,alpha=False)
            for slot in bake_obj.material_slots:
                material=slot.material.copy();slot.material=material;material.use_nodes=True;nodes=material.node_tree.nodes;links=material.node_tree.links
                principled=next(n for n in nodes if n.type=='BSDF_PRINCIPLED');base=principled.inputs['Base Color'];source=base.links[0].from_socket if base.is_linked else None
                # Explicit old UVs prevent the source texture from switching to the new atlas.
                for node in list(nodes):
                    if node.type=='TEX_IMAGE':
                        uvnode=nodes.new('ShaderNodeUVMap');uvnode.uv_map='SourceUV';links.new(uvnode.outputs['UV'],node.inputs['Vector'])
                emission=nodes.new('ShaderNodeEmission');emission.inputs['Color'].default_value=base.default_value
                if source:links.new(source,emission.inputs['Color'])
                output=next(n for n in nodes if n.type=='OUTPUT_MATERIAL');links.new(emission.outputs[0],output.inputs['Surface'])
                target=nodes.new('ShaderNodeTexImage');target.image=image;nodes.active=target
            for other in bpy.context.scene.objects:
                other.hide_render=(other!=bake_obj)
            scene=bpy.context.scene;scene.render.engine='CYCLES';scene.cycles.samples=1;scene.render.bake.margin=4;scene.render.bake.use_clear=True
            bpy.ops.object.bake(type='EMIT')
            from pathlib import Path
            image.filepath_raw=str(Path(args.out).with_suffix(''))+f'_m{index}_albedo.png';image.file_format='PNG';image.save()
            # Only RuntimeUV is exported. SourceUV remains solely for the bake above.
            bake_obj.data.uv_layers.remove(bake_obj.data.uv_layers['SourceUV'])
            mesh=bake_obj.data;obj=bake_obj
        data = dict(dump(obj, mesh, joint_names), **ref)
        for key, arr in data.items():
            out[f"m{index}_{key}"] = arr
        out[f"m{index}_joint_names"] = np.array(joint_names)
        print(f"CRIMSON_DECIMATE mesh={index} name={obj.name} ratio={ratio:.4f} vertices {full} -> {len(data['positions'])} "
              f"triangles {len(data['indices']) // 3}")
    out["repacked_uv"] = np.array(args.repack_uv)
    for key, value in out.items():
        if value.dtype.kind in "fc" and not np.isfinite(value).all():
            raise RuntimeError(f"Non-finite geometry: {key}")
    np.savez_compressed(args.out, **out)
    print(f"CRIMSON_DECIMATE_COMPLETE {args.out}")


if __name__ == "__main__":
    main()
