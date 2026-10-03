"""Export edited Blender armour to the four Godot bone-local mesh contract.

Blender --background --python-exit-code 1 --python THIS --
  --source guardian_refined_editable.blend --rig-json guardian-original-rig.json
  --output editable-export-check.glb --manifest editable-export-manifest.json

The input blend is never saved. No body, rig, animation, or runtime file is exported.
Output must stay beside this delivery script or in one of its subdirectories.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

import bpy
from mathutils import Matrix

EXPECTED_BONES = ("CC_Base_L_Forearm", "CC_Base_R_Upperarm", "CC_Base_L_Upperarm", "CC_Base_Head")
C = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def transform(value):
    return Matrix(((*value["basis_x"], 0), (*value["basis_y"], 0),
                   (*value["basis_z"], 0), (*value["origin"], 1))).transposed()


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", required=True)
parser.add_argument("--rig-json", required=True)
parser.add_argument("--output", required=True)
parser.add_argument("--manifest", required=True)
opts = parser.parse_args(sys.argv[sys.argv.index("--") + 1:])
source, rig_path, output, manifest_path = map(lambda p: Path(p).resolve(),
                                           (opts.source, opts.rig_json, opts.output, opts.manifest))
delivery = Path(__file__).resolve().parent
assert output.is_relative_to(delivery) and manifest_path.is_relative_to(delivery), "Export only within this delivery/source folder"
assert source.suffix == ".blend" and output.suffix == ".glb" and manifest_path.suffix == ".json"
source_hash, rig_hash = sha256(source), sha256(rig_path)
contract = json.loads(rig_path.read_text())
assert len(contract["skeletons"]) == 1
rest = {bone["name"]: transform(bone["global_rest"]) for bone in contract["skeletons"][0]["bones"]}
assert all(name in rest for name in EXPECTED_BONES)
bpy.ops.wm.open_mainfile(filepath=str(source))
armatures = [obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"]
assert len(armatures) == 1
armatures[0].data.pose_position = "REST"
bpy.context.view_layer.update()
parts = [obj for obj in bpy.context.scene.objects if obj.get("bone_name")]
assert parts and {obj["bone_name"] for obj in parts} == set(EXPECTED_BONES), "Expected exactly the four declared bone_name groups"
assert all(obj.type == "MESH" and obj.parent == armatures[0] and obj.parent_type == "BONE"
           and obj.parent_bone == obj["bone_name"] for obj in parts), "Every authored part must be attached to its declared bone"
assert all(not any(mod.type == "ARMATURE" for mod in obj.modifiers) for obj in parts), "Rigid parts must not also be skinned"
palette_set = {mat for obj in parts for mat in obj.data.materials if mat}
assert len(palette_set) == 1, "All four groups must share one palette material"
palette = next(iter(palette_set))
assert palette.use_nodes
assert any(node.type == "VERTEX_COLOR" and node.layer_name == "Color" for node in palette.node_tree.nodes), "Palette must read vertex attribute Color"
exports, groups = [], []
for bone_name in EXPECTED_BONES:
    bpy.ops.object.select_all(action="DESELECT")
    copies = []
    contributors = [obj for obj in parts if obj["bone_name"] == bone_name]
    for obj in contributors:
        # Copy the authored mesh rather than reconstructing it from evaluated
        # geometry: this retains its baked custom loop normals and Color data.
        mesh = obj.data.copy()
        color = mesh.color_attributes.get("Color")
        assert color and color.domain == "CORNER", (obj.name, "missing corner Color")
        assert len(color.data) == len(mesh.loops)
        # First bake the actual REST world transform of the edited, bone-parented
        # object. Blender's imported bone basis/tail adjustments are NOT used as
        # the destination runtime coordinate frame.
        world = obj.matrix_world.copy()
        # Bone-parent keep-transform introduces sub-micro-unit cancellation
        # noise for an originally identity transform. Normalize only this case
        # to avoid changing a planar quad's tie-break during triangulation.
        if max(abs(world[r][c] - float(r == c)) for r in range(4) for c in range(4)) < 1e-6:
            world = Matrix.Identity(4)
        duplicate = obj.copy()
        duplicate.data = mesh
        duplicate.parent = None
        bpy.context.scene.collection.objects.link(duplicate)
        duplicate.matrix_world = world
        duplicate.select_set(True)
        bpy.context.view_layer.objects.active = duplicate
        for modifier in list(duplicate.modifiers):
            bpy.ops.object.modifier_apply(modifier=modifier.name)
        copies.append(duplicate)
    bpy.context.view_layer.objects.active = copies[0]
    bpy.ops.object.join()
    merged = bpy.context.object
    merged.name = bone_name
    to_bone_local = C @ rest[bone_name].inverted() @ C.inverted() @ merged.matrix_world
    for vertex in merged.data.vertices:
        vertex.co = to_bone_local @ vertex.co
    merged.matrix_world = Matrix.Identity(4)
    mod = merged.modifiers.new("Runtime triangulation", "TRIANGULATE")
    bpy.ops.object.modifier_apply(modifier=mod.name)
    merged.data.materials.clear()
    merged.data.materials.append(palette)
    for polygon in merged.data.polygons:
        polygon.material_index = 0
    assert merged.parent is None and not merged.modifiers
    assert merged.data.color_attributes.get("Color")
    exports.append(merged)
    groups.append({"bone": bone_name, "source_parts": [obj.name for obj in contributors],
                   "source_part_count": len(contributors), "vertices_blender": len(merged.data.vertices),
                   "triangles_blender": len(merged.data.polygons),
                   "coordinate_source": "original Godot global_rest from rig JSON, not Blender bone matrix"})
bpy.ops.object.select_all(action="DESELECT")
for obj in exports:
    obj.select_set(True)
bpy.context.view_layer.objects.active = exports[0]
output.parent.mkdir(parents=True, exist_ok=True)
bpy.ops.export_scene.gltf(filepath=str(output), export_format="GLB", use_selection=True,
    export_animations=False, export_skins=False, export_yup=True, export_materials="EXPORT",
    export_vertex_color="MATERIAL", export_all_vertex_colors=True, export_attributes=False)
assert output.is_file() and output.stat().st_size > 1000
raw = output.read_bytes()
length, kind = struct.unpack_from("<II", raw, 12)
assert kind == 0x4e4f534a
gltf = json.loads(raw[20:20 + length])
assert not gltf.get("skins") and not gltf.get("animations")
assert len(gltf.get("meshes", [])) == 4
assert len(gltf.get("materials", [])) == 1
mesh_nodes = [node for node in gltf["nodes"] if "mesh" in node]
assert {node["name"] for node in mesh_nodes} == set(EXPECTED_BONES)
assert all(len(mesh["primitives"]) == 1 and "COLOR_0" in mesh["primitives"][0]["attributes"]
           and mesh["primitives"][0]["material"] == 0 for mesh in gltf["meshes"])
assert sha256(source) == source_hash and sha256(rig_path) == rig_hash
manifest = {"status": "PASS", "blender": bpy.app.version_string,
            "source": str(source), "source_sha256": source_hash,
            "rig_json": str(rig_path), "rig_json_sha256": rig_hash,
            "script": str(Path(__file__).resolve()), "script_sha256": sha256(__file__),
            "output": str(output), "output_sha256": sha256(output), "output_bytes": output.stat().st_size,
            "source_unchanged": True, "runtime_overwritten": False,
            "meshes": len(gltf["meshes"]), "materials": len(gltf["materials"]),
            "skins": 0, "animations": 0, "parts": groups,
            "coordinate_contract": "REST editable world geometry -> C @ original_Godot_global_rest.inverse @ C.inverse; export Y-up; runtime attaches each bone-named mesh under that original bone at identity.",
            "identity_transform_noise_tolerance": 1e-6,
            "scope": "DCC export structure only. Godot geometric equivalence or edited visual acceptance is a separate check."}
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf8")
print("EDITABLE_GUARDIAN_EXPORT_PASS", json.dumps({"output": str(output), "meshes": 4, "parts": len(parts)}))
