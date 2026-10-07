"""Write the race-refinement scenes and body materials (dark, undead, crimson) from parameter tables.

py -3 tools/model_refinement/dark_race_materials.py [--race dark|undead|crimson|all] [--project <GLory root>]

Dark/undead: every refined scene instances the ORIGINAL wrapper (kept unchanged for
rollback) and adds a DarkRefinement node that swaps in the unit's body material and
attaches crafted parts. Crimson: the refined scene instances the refined GLB written by
crimson_refine.py (the original GLB stays unchanged); one body material per glTF
material is attached through the GLB's import settings. Each race has ONE palette (2026-10-04 review: colours
unified): saturated paint is pulled toward the race hue in the shader and every
accent glows in the race glow colour; per unit only *which* painted details glow
(hue bands measured from each atlas) and their strength differ. Dark: violet;
undead: toxic green measured from the small/poison/parasite flames.
The shared runtime (shader, DarkRefinement.gd) lives in dark_refined/shared and
is reused as is by the other races.
"""
import argparse
import json
from pathlib import Path

SHARED = "res://assets/models/units/dark_refined/shared"
OUTLINE = "res://shaders/character_outline.gdshader"

DARK_HUE = 0.77            # ~277 deg, the dominant violet of the eight atlases
DARK_GLOW = (0.48, 0.32, 1.0)  # red ~half of blue: stays violet as it brightens and clips

# Common look; units override below, but never race_hue or the glow/rim colours.
DARK_BASE = {
    "race_hue": DARK_HUE, "hue_unify": 0.85, "unify_min_saturation": 0.18,
    "value_lift": 0.20, "shadow_tint": (0.58, 0.48, 0.72), "light_threshold": 0.32, "band_softness": 0.03,
    "light_energy": 1.25, "light_response": 1.5,
    "accent_color": DARK_GLOW, "accent_hue": 0.78, "accent_hue_width": 0.06,
    "accent_min_saturation": 0.40, "accent_min_value": 0.45, "accent_glow": 0.6,
    "trim_max_saturation": 0.25, "trim_min_value": 0.45, "trim_highlight_color": (0.92, 0.88, 1.0),
    "trim_highlight": 0.45, "trim_gloss": 0.75,
    "rim_color": (0.52, 0.36, 1.0), "rim_strength": 0.22, "rim_power": 2.5, "rim_threshold": 0.56,
    "outline_color": (0.045, 0.018, 0.075), "outline_width": 0.034,
}

DARK_UNITS = {
    "dark_imp": {"wrapper": "res://assets/models/units/dark_imp_motong/dark_imp_motong_animated.tscn",
                 "albedo": "res://assets/models/units/dark_imp_motong/dark_imp_motong_albedo.png",
                 # Its painted flame tips (330-30 deg) glow, now in the race violet.
                 "accent_hue": 0.0, "accent_hue_width": 0.09,
                 "accent_min_saturation": 0.35, "accent_min_value": 0.30, "accent_glow": 1.2},
    "dark_mage": {"wrapper": "res://assets/models/units/dark_mage_violet_necromancer/dark_mage_animated.tscn",
                  "albedo": "res://assets/models/units/dark_mage_violet_necromancer/dark_mage_albedo.png",
                  # Dark hood kept dark; only the brightest violet (lantern orb, sigils) glows and the
                  # skull mask catches a highlight (iteration 01 lifted the whole hood to flat lavender).
                  "value_lift": 0.0, "rim_strength": 0.10, "light_energy": 1.1,
                  "accent_hue": 0.77, "accent_min_value": 0.55, "accent_glow": 1.8,
                  "trim_highlight": 0.7},
    "dark_scythe": {"wrapper": "res://assets/models/units/dark_scythe_animated/dark_scythe_animated.tscn",
                    "albedo": "res://assets/models/units/dark_scythe_animated/dark_scythe_texture.png",
                    # Pale bone/cloth trim; its gold fittings glow (pulled to violet).
                    "accent_hue": 0.07, "accent_hue_width": 0.06,
                    "accent_min_saturation": 0.30, "accent_min_value": 0.30, "accent_glow": 0.45, "trim_highlight": 0.6},
    "dark_suc": {"wrapper": "res://assets/models/units/dark_suc_animated/dark_suc_animated.tscn",
                 "albedo": "res://assets/models/units/dark_suc_animated/dark_suc_albedo.png",
                 # Pink paint is pulled almost fully to violet (review: too pink).
                 "hue_unify": 0.95, "accent_hue": 0.855, "accent_hue_width": 0.06,
                 "accent_min_value": 0.40, "accent_glow": 0.5},
    "dark_fear": {"wrapper": "res://assets/models/units/dark_fear_animated/dark_fear_animated.tscn",
                  "albedo": "res://assets/models/units/dark_fear_animated/dark_fear_texture.png",
                  "accent_hue": 0.77, "accent_min_value": 0.5, "accent_glow": 0.9,
                  "trim_max_saturation": 0.4, "trim_min_value": 0.35},
    "dark_queen": {"wrapper": "res://assets/models/units/dark_queen_animated/dark_queen_animated.tscn",
                   "albedo": "res://assets/models/units/dark_queen_animated/dark_queen_albedo.png",
                   # Pink paint is pulled almost fully to violet (review: too pink).
                   "hue_unify": 0.95, "accent_hue": 0.89, "accent_hue_width": 0.05,
                   "accent_glow": 0.4, "value_lift": 0.2, "trim_highlight": 0.5},
    "dark_doom": {"wrapper": "res://assets/models/units/dark_doom_animated/dark_doom_animated.tscn",
                  "albedo": "res://assets/models/units/dark_doom_animated/dark_doom_albedo.png",
                  "accent_min_value": 0.5, "accent_glow": 0.7,
                  "trim_highlight": 0.8, "trim_gloss": 0.85, "trim_highlight_color": (0.85, 0.85, 1.0)},
    "dark_dragon": {"wrapper": "res://assets/models/units/dark_dragon_animated/dark_dragon_animated.tscn",
                    "albedo": "res://assets/models/units/dark_dragon_animated/dark_dragon_texture.png",
                    "accent_hue": 0.77, "accent_min_value": 0.5, "accent_glow": 1.0},
}

UNDEAD_HUE = 0.253          # ~91 deg, median of the small/poison/parasite flame paint
UNDEAD_GLOW = (0.42, 1.0, 0.14)  # red ~0.4x green: stays toxic green, never clips to yellow

UNDEAD_BASE = {
    "race_hue": UNDEAD_HUE, "hue_unify": 0.85, "unify_min_saturation": 0.18,
    "value_lift": 0.12, "shadow_tint": (0.52, 0.60, 0.50), "light_threshold": 0.32, "band_softness": 0.03,
    "light_energy": 1.2, "light_response": 1.5,
    # Only the brightest flame paint glows.
    "accent_color": UNDEAD_GLOW, "accent_hue": UNDEAD_HUE, "accent_hue_width": 0.07,
    "accent_min_saturation": 0.45, "accent_min_value": 0.55, "accent_glow": 0.6,
    "trim_max_saturation": 0.25, "trim_min_value": 0.45, "trim_highlight_color": (0.90, 1.0, 0.88),
    "trim_highlight": 0.45, "trim_gloss": 0.75,
    "rim_color": (0.45, 1.0, 0.32), "rim_strength": 0.18, "rim_power": 2.5, "rim_threshold": 0.56,
    "outline_color": (0.020, 0.035, 0.016), "outline_width": 0.034,
}


def undead(name: str, **spec) -> dict:
    base = f"res://assets/models/units/undead_{name}_animated"
    return {"wrapper": f"{base}/undead_{name}_animated.tscn", "albedo": f"{base}/undead_{name}_texture.png", **spec}


UNDEAD_UNITS = {
    "undead_small": undead("small"),
    "undead_poison": undead("poison"),
    "undead_parasite": undead("parasite", value_lift=0.2),
    "undead_spike": undead("spike", value_lift=0.18),
    # Already bright paint: no lift.
    "undead_fly": undead("fly", value_lift=0.0),
    # Very dark body; its yellow pustules (45-60 deg) glow as the bomb's tell.
    "undead_bomb": undead("bomb", value_lift=0.28, accent_hue=0.145, accent_hue_width=0.06,
                          accent_min_saturation=0.35, accent_min_value=0.35, accent_glow=0.9),
    "undead_titan": undead("titan", value_lift=0.22, trim_highlight=0.7),
    # The mustard cloak is pulled to olive and darkened (iteration 01 still read yellow);
    # its cloak has inward-facing triangles that showed the black outline shell: two-sided.
    "undead_mother": undead("mother", value_lift=0.0, hue_unify=0.95, body_tint=(0.64, 0.70, 0.58), two_sided=True),
}

CRIMSON_HUE = 0.989         # ~356 deg, median red of the eight Meshy base colour maps
CRIMSON_GLOW = (1.0, 0.16, 0.18)  # green/blue kept low: stays red as it brightens, never orange

CRIMSON_BASE = {
    # Skin, bone, fur and brown wood sit next to red on the hue wheel: only clearly saturated
    # paint (orange-red props) is pulled, or everything turns pink (iteration 01). The shadow
    # floor stays warm-neutral: a red shadow tint turned shaded skin pink (iteration 02).
    "race_hue": CRIMSON_HUE, "hue_unify": 0.85, "unify_min_saturation": 0.50,
    "value_lift": 0.10, "shadow_tint": (0.58, 0.55, 0.52), "light_threshold": 0.32, "band_softness": 0.08,
    "light_energy": 1.2, "light_response": 1.5,
    # Most of the paint is already saturated red: only the brightest of it glows, faintly.
    "accent_color": CRIMSON_GLOW, "accent_hue": CRIMSON_HUE, "accent_hue_width": 0.05,
    "accent_min_saturation": 0.60, "accent_min_value": 0.85, "accent_glow": 0.15,
    "trim_max_saturation": 0.25, "trim_min_value": 0.50, "trim_highlight_color": (1.0, 0.95, 0.88),
    "trim_highlight": 0.45, "trim_gloss": 0.75,
    "rim_color": (1.0, 0.30, 0.24), "rim_strength": 0.12, "rim_power": 2.5, "rim_threshold": 0.56,
    "outline_color": (0.060, 0.012, 0.015), "outline_width": 0.030, "outline_max_pixels": 0.55,
    # Every Meshy material is double-sided (hair cards, feathers).
    "two_sided": True, "normal_depth": 0.15,
}

CRIMSON_UNITS = {unit: {} for unit in ("crimson", "dancer", "drumer", "hunter", "armbreaker", "skypierce", "lattern")}
# Recoloured hair (crimson_refine.py) is bright saturated red end to end: no glow, or it reads as a flat blob.
CRIMSON_UNITS["Icey"] = {"accent_glow": 0.0}
# Darkest base colours of the race (maroon hair, dark leather): open the shadows a little more.
CRIMSON_UNITS["dancer"] = {"value_lift": 0.22}

RACES = {
    "dark": {"base": DARK_BASE, "units": DARK_UNITS, "parts_material": f"{SHARED}/dark_parts.tres"},
    "undead": {"base": UNDEAD_BASE, "units": UNDEAD_UNITS,
               "parts_material": "res://assets/models/units/undead_refined/undead_parts.tres"},
    "crimson": {"base": CRIMSON_BASE, "units": CRIMSON_UNITS, "glb": True},
}


def value(v):
    if isinstance(v, tuple):
        return "Color(%s, 1)" % ", ".join("%.3f" % c for c in v) if len(v) == 3 else repr(v)
    return "%.3f" % v if isinstance(v, float) else str(v)


TEXTURE_IMPORT = """[remap]

importer="texture"
type="CompressedTexture2D"

[params]

compress/mode=2
compress/high_quality=false
compress/lossy_quality=0.7
compress/normal_map={normal}
mipmaps/generate=true
mipmaps/limit=-1
process/fix_alpha_border=true
process/size_limit=1024
detect_3d/compress_to=0
"""


def refined_textures(project: Path, race: str, unit_id: str, prefix: str | None = None) -> dict:
    """Cleaned sources (<prefix>_albedo.png, <prefix>_normal.png) from dark_race_textures.py or
    crimson_refine.py; write their import settings once."""
    folder = project / f"assets/models/units/{race}_refined" / unit_id
    found = {}
    for kind, normal in (("albedo", 0), ("normal", 1)):
        source = folder / f"{prefix or unit_id}_{kind}.png"
        if source.is_file():
            sidecar = source.with_suffix(".png.import")
            if not sidecar.exists():
                sidecar.write_text(TEXTURE_IMPORT.format(normal=normal), encoding="utf-8", newline="\n")
            found[kind] = f"res://assets/models/units/{race}_refined/{unit_id}/{source.name}"
    return found


def outline_material(p: dict) -> str:
    return "\n".join(['[gd_resource type="ShaderMaterial" load_steps=2 format=3]', "",
                      f'[ext_resource type="Shader" path="{OUTLINE}" id="1"]', "",
                      "[resource]", "render_priority = -1", 'shader = ExtResource("1")',
                      f'shader_parameter/outline_color = {value(p["outline_color"])}',
                      f'shader_parameter/outline_width = {value(p["outline_width"])}',
                      *([f'shader_parameter/outline_max_pixels = {value(p["outline_max_pixels"])}']
                        if "outline_max_pixels" in p else [])]) + "\n"


def material(race: str, unit_id: str, spec: dict, textures: dict, outline: str | None = None) -> str:
    """Body material; the outline pass is embedded, or the shared race outline when given
    (crimson: one outline for all surfaces keeps multi-material units within 4 materials)."""
    p = dict(RACES[race]["base"], **spec)
    if "albedo" in textures:
        p["albedo"] = textures["albedo"]
    steps = 4 + ("normal" in textures) + (outline is None)
    lines = [f'[gd_resource type="ShaderMaterial" load_steps={steps} format=3]', "",
             f'[ext_resource type="Shader" path="{SHARED}/{"dark_body_two_sided" if p.get("two_sided") else "dark_body"}.gdshader" id="1"]',
             f'[ext_resource type="Texture2D" path="{p["albedo"]}" id="2"]',
             (f'[ext_resource type="Material" path="{outline}" id="3"]' if outline else f'[ext_resource type="Shader" path="{OUTLINE}" id="3"]'),
             *([f'[ext_resource type="Texture2D" path="{textures["normal"]}" id="4"]'] if "normal" in textures else []), ""]
    if outline is None:
        lines += ['[sub_resource type="ShaderMaterial" id="Outline"]', "render_priority = -1",
                  'shader = ExtResource("3")',
                  f'shader_parameter/outline_color = {value(p["outline_color"])}',
                  f'shader_parameter/outline_width = {value(p["outline_width"])}', ""]
    lines += ["[resource]", f'resource_name = "{unit_id}_refined_body"',
              f'next_pass = {"ExtResource(\"3\")" if outline else "SubResource(\"Outline\")"}',
              'shader = ExtResource("1")', 'shader_parameter/albedo_texture = ExtResource("2")']
    for key, v in p.items():
        if key in ("wrapper", "albedo", "outline_color", "outline_width", "outline_max_pixels", "normal_depth", "two_sided"):
            continue
        lines.append(f"shader_parameter/{key} = {value(v)}")
    if "normal" in textures:
        lines += ["shader_parameter/use_normal_map = true", 'shader_parameter/normal_map_texture = ExtResource("4")',
                  f"shader_parameter/normal_map_depth = {value(p.get('normal_depth', 0.35))}"]
    return "\n".join(lines) + "\n"


def scene(race: str, unit_id: str, spec: dict, has_parts: bool) -> str:
    root = "".join(w.capitalize() for w in unit_id.split("_")) + "Refined"
    folder = f"res://assets/models/units/{race}_refined/{unit_id}"
    ext = [f'[ext_resource type="PackedScene" path="{spec["wrapper"]}" id="1"]',
           f'[ext_resource type="Script" path="{SHARED}/DarkRefinement.gd" id="2"]',
           f'[ext_resource type="Material" path="{folder}/{unit_id}_body.tres" id="3"]']
    props = ['script = ExtResource("2")', 'body_material = ExtResource("3")']
    if has_parts:
        ext += [f'[ext_resource type="PackedScene" path="{folder}/{unit_id}_parts.glb" id="4"]',
                f'[ext_resource type="Material" path="{RACES[race]["parts_material"]}" id="5"]']
        props += ['parts = ExtResource("4")', 'parts_material = ExtResource("5")']
    return "\n".join([f"[gd_scene load_steps={len(ext) + 1} format=3]", "", *ext, "",
                      f'[node name="{root}" instance=ExtResource("1")]', "",
                      '[node name="DarkRefinement" type="Node" parent="."]', *props]) + "\n"


# Mirrors the original crimson GLB imports so only the materials differ.
GLB_IMPORT = """[remap]

importer="scene"
importer_version=1
type="PackedScene"

[params]

nodes/root_type=""
nodes/root_name=""
nodes/root_script=null
mesh_library/use_node_names_as_mesh_names=false
array_mesh/deduplicate_surfaces=true
nodes/apply_root_scale=true
nodes/root_scale=1.0
nodes/import_as_skeleton_bones=false
nodes/use_name_suffixes=true
nodes/use_node_type_suffixes=true
meshes/ensure_tangents=true
meshes/generate_lods=true
meshes/create_shadow_meshes=true
meshes/light_baking=1
meshes/lightmap_texel_size=0.2
meshes/force_disable_compression=false
skins/use_named_skins=true
animation/import=true
animation/fps=30
animation/trimming=false
animation/remove_immutable_tracks=true
animation/import_rest_as_RESET=false
import_script/path=""
materials/extract=0
materials/extract_format=0
materials/extract_path=""
_subresources={subresources}
gltf/naming_version=2
gltf/embedded_image_handling=1
gltf/texture_map_mode=1
"""


def glb_unit(project: Path, race: str, unit_id: str, spec: dict) -> str:
    """Crimson: one body material per glTF material, attached through the refined GLB's import settings."""
    folder = project / f"assets/models/units/{race}_refined" / unit_id
    refine = json.loads((folder / "refine.json").read_text(encoding="utf-8"))
    res = f"res://assets/models/units/{race}_refined/{unit_id}"
    outline = f"res://assets/models/units/{race}_refined/{race}_outline.tres"
    (folder.parent / f"{race}_outline.tres").write_text(outline_material(RACES[race]["base"]), encoding="utf-8", newline="\n")
    external = {}
    for row in refine["textures"]:
        name = f"{unit_id}_m{row['index']}"
        textures = refined_textures(project, race, unit_id, name)
        if refine.get("repacked_uv", False):
            textures.pop("normal", None)
        (folder / f"{name}.tres").write_text(material(race, name, spec, textures, outline), encoding="utf-8", newline="\n")
        external[row["material"]] = {"use_external/enabled": True, "use_external/path": f"{res}/{name}.tres"}
    (folder / f"{unit_id}_refined.glb.import").write_text(
        GLB_IMPORT.format(subresources=json.dumps({"materials": external})), encoding="utf-8", newline="\n")
    root = unit_id[:1].upper() + unit_id[1:] + "Refined"
    (folder / f"{unit_id}_refined.tscn").write_text("\n".join([
        "[gd_scene load_steps=2 format=3]", "",
        f'[ext_resource type="PackedScene" path="{res}/{unit_id}_refined.glb" id="1"]', "",
        f'[node name="{root}" instance=ExtResource("1")]']) + "\n", encoding="utf-8", newline="\n")
    return f"{unit_id}: {len(external)} materials + import + scene written"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--race", choices=[*RACES, "all"], default="all")
    args = parser.parse_args()
    project = Path(args.project)
    for race in (RACES if args.race == "all" else [args.race]):
        for unit_id, spec in RACES[race]["units"].items():
            if RACES[race].get("glb"):
                print(glb_unit(project, race, unit_id, spec))
                continue
            folder = project / f"assets/models/units/{race}_refined" / unit_id
            folder.mkdir(parents=True, exist_ok=True)
            has_parts = (folder / f"{unit_id}_parts.glb").is_file()
            textures = refined_textures(project, race, unit_id)
            (folder / f"{unit_id}_body.tres").write_text(material(race, unit_id, spec, textures), encoding="utf-8", newline="\n")
            (folder / f"{unit_id}_refined.tscn").write_text(scene(race, unit_id, spec, has_parts), encoding="utf-8", newline="\n")
            print(f"{unit_id}: material + scene written (textures={sorted(textures)}, parts={'yes' if has_parts else 'no'})")


if __name__ == "__main__":
    main()
