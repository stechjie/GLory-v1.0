"""Build the isolated Crimson guard optimization candidate with Blender 5.2.

The source GLB remains untouched. This pilot only reduces redundant surface
triangles; visual and animation checks decide whether the candidate is usable.
"""

from pathlib import Path
import os
import bpy


PROJECT = Path(__file__).resolve().parents[2]
SOURCE = PROJECT / "assets/models/units/crimson_race/crimson.glb"
TAG = os.environ.get("CRIMSON_PILOT_TAG", "")
SUFFIX = f"_{TAG}" if TAG else ""
OUT = PROJECT / "assets/models/units" / f"crimson_guard_pilot{SUFFIX}"
EDITABLE = Path(os.environ.get("CRIMSON_EDITABLE_DIR", str(PROJECT.parent / "crimson_model_editable")))
BLEND = EDITABLE / f"crimson_guard_pilot{SUFFIX}.blend"
GLB = OUT / f"crimson_guard_pilot{SUFFIX}.glb"
RATIO = float(os.environ.get("CRIMSON_PILOT_RATIO", "0.78"))


def main() -> None:
    if not SOURCE.is_file():
        raise FileNotFoundError(SOURCE)
    OUT.mkdir(parents=True, exist_ok=True)
    EDITABLE.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(SOURCE))
    meshes = [obj for obj in bpy.data.objects if obj.type == "MESH" and obj.name == "output_unwrapped"]
    armatures = [obj for obj in bpy.data.objects if obj.type == "ARMATURE"]
    if len(meshes) != 1 or len(armatures) != 1:
        raise RuntimeError(f"Unexpected source structure: {[(obj.name, obj.type) for obj in bpy.data.objects]}")
    mesh = meshes[0]
    before = (len(mesh.data.vertices), len(mesh.data.polygons))
    decimate = mesh.modifiers.new("Guard silhouette budget", "DECIMATE")
    decimate.ratio = RATIO
    decimate.use_collapse_triangulate = True
    bpy.context.view_layer.objects.active = mesh
    mesh.select_set(True)
    while mesh.modifiers[0] != decimate:
        bpy.ops.object.modifier_move_up(modifier=decimate.name)
    bpy.ops.object.modifier_apply(modifier=decimate.name)
    after = (len(mesh.data.vertices), len(mesh.data.polygons))
    if after[0] >= before[0] or not mesh.vertex_groups:
        raise RuntimeError(f"Geometry or skinning invalid: {before} -> {after}")
    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND))
    bpy.ops.export_scene.gltf(
        filepath=str(GLB),
        export_format="GLB",
        export_image_format="AUTO",
        export_animations=True,
    )
    if not GLB.is_file() or GLB.stat().st_size < 100_000:
        raise RuntimeError("GLB export failed")
    print(f"CRIMSON_GUARD_PILOT source={SOURCE} vertices/faces={before} -> {after} blend={BLEND} glb={GLB}")


if __name__ == "__main__":
    main()
