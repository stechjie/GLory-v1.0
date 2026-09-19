"""Build Glory's first Blender-authored VFX projectile.

Produces an editable .blend, a compact Godot GLB, and a transparent review
render. The build is deterministic and needs no external add-ons or textures.
"""

from __future__ import annotations

import math
from pathlib import Path

import bpy
from mathutils import Vector


SCRIPT_PATH = Path(__file__).resolve()
PROJECT_ROOT = SCRIPT_PATH.parents[4]
SOURCE_DIR = SCRIPT_PATH.parent
GLB_PATH = PROJECT_ROOT / "assets" / "vfx" / "meshes" / "poison_glob_trial.glb"
BLEND_PATH = SOURCE_DIR / "poison_glob_trial.blend"
PREVIEW_PATH = Path(r"C:\Users\Leno\Desktop\imgae\blender_poison_glob_trial_preview.png")


def reset_scene() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)


def make_material(name: str, base: tuple[float, float, float, float], roughness: float,
                  emission: tuple[float, float, float, float], emission_strength: float) -> bpy.types.Material:
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    material.diffuse_color = base
    principled = material.node_tree.nodes.get("Principled BSDF")
    principled.inputs["Base Color"].default_value = base
    principled.inputs["Roughness"].default_value = roughness
    principled.inputs["Metallic"].default_value = 0.0
    emission_socket = "Emission Color" if "Emission Color" in principled.inputs else "Emission"
    principled.inputs[emission_socket].default_value = emission
    principled.inputs["Emission Strength"].default_value = emission_strength
    return material


def create_tube(name: str, points: list[tuple[float, float, float]], radii: list[float],
                segments: int, materials: list[bpy.types.Material], phase: float = 0.0) -> bpy.types.Object:
    vertices: list[tuple[float, float, float]] = []
    faces: list[tuple[int, ...]] = []
    ring_count = len(points)
    for ring_index, ((x, y, z), radius) in enumerate(zip(points, radii)):
        for segment in range(segments):
            angle = math.tau * segment / segments
            irregular = 1.0 + 0.105 * math.sin(angle * 3.0 + ring_index * 1.71 + phase)
            irregular += 0.052 * math.cos(angle * 5.0 - ring_index * 0.83 + phase * 0.7)
            flatten = 0.82 + 0.05 * math.sin(ring_index * 1.13 + phase)
            vertices.append((x, y + math.cos(angle) * radius * irregular,
                             z + math.sin(angle) * radius * irregular * flatten))
    for ring_index in range(ring_count - 1):
        for segment in range(segments):
            current = ring_index * segments + segment
            next_segment = ring_index * segments + (segment + 1) % segments
            upper = (ring_index + 1) * segments + segment
            upper_next = (ring_index + 1) * segments + (segment + 1) % segments
            faces.append((current, upper, upper_next, next_segment))
    faces.append(tuple(reversed(range(segments))))
    last_ring = (ring_count - 1) * segments
    faces.append(tuple(last_ring + segment for segment in range(segments)))

    mesh = bpy.data.meshes.new(name + "Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    for material in materials:
        mesh.materials.append(material)
    for polygon in mesh.polygons:
        center = polygon.center
        # Keep the shadow band continuous. Random per-face material assignment
        # creates a checkerboard that reads as a placeholder at game distance.
        shadow_edge = -0.16 + 0.045 * math.sin(center.x * 4.2 + phase)
        polygon.material_index = 0 if center.z < shadow_edge else 1
        polygon.use_smooth = False
    return obj


def create_droplet(name: str, location: tuple[float, float, float], scale: tuple[float, float, float],
                   material: bpy.types.Material, phase: float) -> bpy.types.Object:
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=1.0, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    for vertex in obj.data.vertices:
        direction = vertex.co.normalized()
        vertex.co *= 1.0 + 0.14 * math.sin(direction.x * 5.2 + direction.y * 7.3 + phase)
    obj.data.materials.append(material)
    for polygon in obj.data.polygons:
        polygon.use_smooth = False
    return obj


def look_at(obj: bpy.types.Object, target: tuple[float, float, float]) -> None:
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()


def build_asset() -> tuple[bpy.types.Object, list[bpy.types.Object]]:
    dark = make_material("Poison_DarkViolet", (0.035, 0.008, 0.055, 1.0), 0.78,
                         (0.055, 0.01, 0.08, 1.0), 0.18)
    body = make_material("Poison_SicklyGreen", (0.11, 0.34, 0.018, 1.0), 0.62,
                         (0.12, 0.52, 0.012, 1.0), 0.42)
    core = make_material("Poison_HotCore", (0.46, 0.80, 0.055, 1.0), 0.34,
                         (0.48, 0.90, 0.035, 1.0), 1.25)

    root = bpy.data.objects.new("PoisonGlobRoot", None)
    bpy.context.collection.objects.link(root)
    root["glory_vfx_role"] = "projectile"
    root["forward_axis"] = "+X"
    root["triangle_budget"] = 900

    body_points = [
        (-1.14, 0.03, -0.01), (-0.91, -0.05, 0.05), (-0.61, 0.06, -0.05),
        (-0.25, -0.055, 0.055), (0.14, 0.035, -0.035), (0.47, -0.06, 0.015),
        (0.72, 0.035, -0.055), (0.88, -0.025, -0.02),
    ]
    # A heavy blunt leading mass replaces the pointed fish-like nose from v1.
    body_radii = [0.12, 0.32, 0.58, 0.73, 0.76, 0.70, 0.59, 0.43]
    objects = [create_tube("PoisonBody", body_points, body_radii, 12, [dark, body], 0.35)]

    tail_specs = [
        ("PoisonTendrilUpper", 0.30, 0.17, 0.0),
        ("PoisonTendrilMiddle", -0.16, -0.03, 1.7),
        ("PoisonTendrilLower", 0.08, -0.24, 3.1),
    ]
    for name, y_bias, z_bias, phase in tail_specs:
        points, radii = [], []
        for index in range(8):
            ratio = index / 7.0
            points.append((
                -0.78 - ratio * (1.45 + 0.13 * math.sin(phase)),
                y_bias * ratio + math.sin(ratio * math.pi * 2.2 + phase) * 0.105 * ratio,
                z_bias * ratio + math.cos(ratio * math.pi * 1.7 + phase) * 0.075 * ratio,
            ))
            radii.append(0.17 * (1.0 - ratio) + 0.032)
        objects.append(create_tube(name, points, radii, 8, [dark, body], phase))

    for name, location, scale, phase in [
        ("PoisonDropletA", (-2.39, 0.34, 0.13), (0.18, 0.12, 0.105), 0.2),
        ("PoisonDropletB", (-2.22, -0.23, -0.25), (0.13, 0.09, 0.08), 1.4),
        ("PoisonDropletC", (-1.92, 0.05, 0.28), (0.10, 0.075, 0.065), 2.8),
    ]:
        objects.append(create_droplet(name, location, scale, body, phase))

    for name, location, scale, phase in [
        ("PoisonCoreLarge", (0.23, -0.66, 0.12), (0.15, 0.060, 0.14), 0.4),
        ("PoisonCoreSmallA", (-0.16, -0.66, -0.10), (0.085, 0.045, 0.08), 1.2),
        ("PoisonCoreSmallB", (0.55, -0.57, -0.12), (0.070, 0.040, 0.065), 2.3),
    ]:
        objects.append(create_droplet(name, location, scale, core, phase))

    for name, location, scale, phase in [
        ("PoisonVioletCrustA", (-0.52, 0.50, 0.20), (0.24, 0.09, 0.13), 0.8),
        ("PoisonVioletCrustB", (0.44, 0.40, -0.22), (0.19, 0.08, 0.10), 2.0),
    ]:
        objects.append(create_droplet(name, location, scale, dark, phase))

    for obj in objects:
        obj.parent = root
    return root, objects


def triangle_count(objects: list[bpy.types.Object]) -> int:
    total = 0
    for obj in objects:
        obj.data.calc_loop_triangles()
        total += len(obj.data.loop_triangles)
    return total


def export_glb(root: bpy.types.Object, objects: list[bpy.types.Object]) -> None:
    GLB_PATH.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    root.select_set(True)
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = root
    bpy.ops.export_scene.gltf(filepath=str(GLB_PATH), export_format="GLB", use_selection=True,
                              export_yup=True, export_apply=True, export_animations=False,
                              export_cameras=False, export_lights=False)


def setup_preview() -> None:
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 960
    scene.render.resolution_y = 540
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    scene.render.film_transparent = True
    scene.render.filepath = str(PREVIEW_PATH)

    camera_data = bpy.data.cameras.new("ReviewCamera")
    camera = bpy.data.objects.new("ReviewCamera", camera_data)
    bpy.context.collection.objects.link(camera)
    camera.location = (3.9, -7.6, 3.45)
    camera.data.type = "ORTHO"
    camera.data.ortho_scale = 4.7
    look_at(camera, (-0.35, 0.0, 0.0))
    scene.camera = camera

    key_data = bpy.data.lights.new("WarmKey", "AREA")
    key = bpy.data.objects.new("WarmKey", key_data)
    bpy.context.collection.objects.link(key)
    key.location = (2.8, -3.2, 5.0)
    key_data.energy = 620.0
    key_data.shape = "DISK"
    key_data.size = 4.0
    key_data.color = (0.88, 1.0, 0.70)
    look_at(key, (0.0, 0.0, 0.0))

    rim_data = bpy.data.lights.new("VioletRim", "AREA")
    rim = bpy.data.objects.new("VioletRim", rim_data)
    bpy.context.collection.objects.link(rim)
    rim.location = (-3.0, 2.7, 2.2)
    rim_data.energy = 480.0
    rim_data.size = 3.0
    rim_data.color = (0.42, 0.10, 0.72)
    look_at(rim, (-0.4, 0.0, 0.0))

    scene.world.color = (0.008, 0.010, 0.012)
    PREVIEW_PATH.parent.mkdir(parents=True, exist_ok=True)


def main() -> None:
    reset_scene()
    root, objects = build_asset()
    triangles = triangle_count(objects)
    print(f"GLORY_POISON_GLOB triangles={triangles} objects={len(objects)}")
    if triangles > 900:
        raise RuntimeError(f"Triangle budget exceeded: {triangles} > 900")
    export_glb(root, objects)
    setup_preview()
    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND_PATH))
    bpy.ops.render.render(write_still=True)
    print(f"GLORY_POISON_GLOB blend={BLEND_PATH}")
    print(f"GLORY_POISON_GLOB glb={GLB_PATH}")
    print(f"GLORY_POISON_GLOB preview={PREVIEW_PATH}")


if __name__ == "__main__":
    main()
