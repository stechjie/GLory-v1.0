"""Writes the refined formation-ally materials, wrapper scenes and texture
import settings under res://assets/models/allies_refined/<id>/.

Re-run after ally_textures.py (which writes the *_albedo.png / *_emission.png):
    python3 tools/model_refinement/allies/build_ally_refined.py <project_root>

Nothing under res://assets/models/allies/ is touched; scenes reference the
original action FBX in place. The only data change is the five `model` fields
in data/formation/formation_allies.json (done separately, see --apply-data).
"""
import json, os, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
APPLY_DATA = "--apply-data" in sys.argv
SRC = "res://assets/models/allies"
DST = "res://assets/models/allies_refined"

# Per-unit look (2026-10-12 round 2, user: 每只更有辨识度 + 身上加火焰).
# Each ally owns one signature colour, shared by the recoloured lava paint
# (ally_textures.py RECOLOR), the emission glow, the rim and its body fire:
#   flame_claw amber, soul_chain cyan soul-fire, abyss_beast acid green,
#   hell_inferno crimson hellfire, eternal_night violet night-fire.
# Plus: lifted shadow band, outline pass, bone-attached flames (flame_points:
# candidate bone names per point, first match on each action skeleton).
def F(bones, size, amount=10, lifetime=0.6, rise=1.8, radius=0.06, lift=0.0):
    return dict(bones=bones, size=size, amount=amount, lifetime=lifetime, rise=rise, radius=radius, lift=lift)

UNITS = {
    "ally_flame_claw": dict(src="formation_ally_1_animated", tex="flame_claw", name="Flameclaw Imp",
        shadow=(0.60, 0.48, 0.42), light_energy=1.45, rim=(1.0, 0.62, 0.22), rim_strength=0.22,
        emission=(1.0, 0.62, 0.16), emission_energy=1.9, normal=f"{SRC}/formation_ally_1_animated/flame_claw_normal.png",
        normal_depth=0.16, spec=0.0, outline=0.022, anims=True, scales={},
        flame=dict(core=(1.0, 0.88, 0.45), mid=(1.0, 0.5, 0.06), edge=(0.6, 0.12, 0.0), intensity=1.3),
        flames=[F(["spine"], 0.62, 16, radius=0.22, lift=0.55), F(["chest"], 0.56, 14, radius=0.2, lift=0.5),
                F(["head"], 0.36, 10, radius=0.1, lift=0.18), F(["front_paw.L"], 0.34, 8, lift=0.06), F(["front_paw.R"], 0.34, 8, lift=0.06)]),
    "ally_soul_chain": dict(src="formation_ally_2_animated", tex="texture", name="Soulchain Warden",
        shadow=(0.52, 0.60, 0.66), light_energy=1.40, rim=(0.35, 0.9, 1.0), rim_strength=0.22,
        emission=(0.25, 0.88, 1.0), emission_energy=1.5, normal=f"{SRC}/formation_ally_2_animated/normal.png",
        normal_depth=0.12, spec=0.0, outline=0.022, anims=False, scales={"run": 580.0}, yaws={"run": 30.0}, offsets={"run": 0.2},
        flame=dict(core=(0.7, 1.0, 1.0), mid=(0.1, 0.7, 1.0), edge=(0.0, 0.15, 0.55), intensity=1.4),
        flames=[F(["Bone.010", "head"], 0.42, 12, radius=0.12, lift=0.25), F(["Bone.004", "chest"], 0.56, 16, radius=0.2, lift=0.35),
                F(["Bone.022", "tail3"], 0.40, 10, lift=0.05), F(["front_paw.01.L", "frontleg2"], 0.30, 8, lift=0.05), F(["front_paw.01.R", "R_frontleg2"], 0.30, 8, lift=0.05)]),
    "ally_abyss_beast": dict(src="formation_ally_3_animated", tex="texture", name="Abyss Devourer",
        shadow=(0.56, 0.62, 0.52), light_energy=1.40, rim=(0.55, 1.0, 0.25), rim_strength=0.22,
        emission=(0.5, 1.0, 0.15), emission_energy=1.4, normal=f"{SRC}/formation_ally_3_animated/normal.png",
        normal_depth=0.12, spec=0.0, outline=0.022, anims=False, scales={},
        flame=dict(core=(0.7, 1.0, 0.4), mid=(0.35, 0.95, 0.05), edge=(0.02, 0.3, 0.02), intensity=1.4),
        flames=[F(["head_02"], 0.46, 14, radius=0.16, lift=0.32), F(["spine_03"], 0.42, 12, radius=0.14, lift=0.25),
                F(["hand_07.l"], 0.34, 9, lift=0.05), F(["hand_07.r"], 0.34, 9, lift=0.05)]),
    "ally_hell_inferno": dict(src="formation_ally_4_animated", tex="texture", name="Inferno Ravager",
        shadow=(0.62, 0.50, 0.50), light_energy=1.40, rim=(1.0, 0.35, 0.15), rim_strength=0.22,
        emission=(1.0, 0.28, 0.08), emission_energy=1.6, normal=None, normal_depth=0.0,
        spec=0.35, outline=0.018, anims=False, scales={"run": 355.0},
        flame=dict(core=(1.0, 0.5, 0.22), mid=(0.92, 0.07, 0.02), edge=(0.4, 0.0, 0.02), intensity=1.4),
        flames=[F(["bodymid02", "Hips"], 0.62, 18, radius=0.24, lift=0.45), F(["bodyend02", "tailstart"], 0.54, 14, radius=0.2, lift=0.4),
                F(["head"], 0.40, 10, radius=0.1, lift=0.2), F(["taillast", "tail3"], 0.42, 10, lift=0.05),
                F(["handlast.l", "frontleg2"], 0.34, 8, lift=0.05), F(["handlast.r", "R_frontleg2"], 0.34, 8, lift=0.05)]),
    "ally_eternal_night": dict(src="formation_ally_5_animated", tex="texture", name="Eternal Night",
        shadow=(0.58, 0.50, 0.66), light_energy=1.40, rim=(0.75, 0.4, 1.0), rim_strength=0.22,
        emission=(0.72, 0.32, 1.0), emission_energy=1.6, normal=None, normal_depth=0.0,
        spec=0.35, outline=0.018, anims=False, scales={},
        flame=dict(core=(0.85, 0.65, 1.0), mid=(0.55, 0.15, 1.0), edge=(0.18, 0.0, 0.45), intensity=1.4),
        flames=[F(["hand04.l"], 0.42, 12, lift=0.05), F(["hand04.r"], 0.42, 12, lift=0.05), F(["Bone.004"], 0.42, 12, radius=0.1, lift=0.12),
                F(["hand02.l"], 0.40, 10, radius=0.08, lift=0.1), F(["hand02.r"], 0.40, 10, radius=0.08, lift=0.1),
                F(["pifeng03.l"], 0.36, 9, lift=0.03), F(["pifeng03.r"], 0.36, 9, lift=0.03)]),
}


def flame_material(uid, u):
    f = u["flame"]
    return "\n".join([
        '[gd_resource type="ShaderMaterial" load_steps=2 format=3]', "",
        f'[ext_resource type="Shader" path="{DST}/shared/ally_flame.gdshader" id="1_flame"]', "",
        '[resource]', f'resource_name = "{uid}_flame_material"', 'render_priority = 1',
        'shader = ExtResource("1_flame")',
        f'shader_parameter/core_color = {col(f["core"])}',
        f'shader_parameter/mid_color = {col(f["mid"])}',
        f'shader_parameter/edge_color = {col(f["edge"])}',
        f'shader_parameter/intensity = {f["intensity"]}', ""])


def gd_value(v):
    if isinstance(v, dict):
        return "{" + ", ".join(f'"{k}": {gd_value(x)}' for k, x in v.items()) + "}"
    if isinstance(v, (list, tuple)):
        return "[" + ", ".join(gd_value(x) for x in v) + "]"
    if isinstance(v, str):
        return json.dumps(v)
    return repr(v)


TEX_IMPORT = """[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="{path}"

[params]

compress/mode=2
compress/high_quality=false
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map=0
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=true
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=1024
detect_3d/compress_to=0
"""


def col(c):
    return "Color(%g, %g, %g, 1)" % c


def write(rel, text):
    p = os.path.join(ROOT, rel.replace("res://", ""))
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    return p


def material(uid, u):
    base = f"{DST}/{uid}/{uid}_body"
    ext = [f'[ext_resource type="Shader" path="res://shaders/character_toon.gdshader" id="1_toon"]',
           f'[ext_resource type="Shader" path="res://shaders/character_outline.gdshader" id="2_outline"]',
           f'[ext_resource type="Texture2D" path="{base}_albedo.png" id="3_albedo"]',
           f'[ext_resource type="Texture2D" path="{base}_emission.png" id="4_emission"]']
    if u["normal"]:
        ext.append(f'[ext_resource type="Texture2D" path="{u["normal"]}" id="5_normal"]')
    lines = [f'[gd_resource type="ShaderMaterial" load_steps={len(ext) + 2} format=3]', ""] + ext + ["",
        '[sub_resource type="ShaderMaterial" id="ShaderMaterial_outline"]',
        'render_priority = -1',
        'shader = ExtResource("2_outline")',
        'shader_parameter/outline_color = Color(0.04, 0.012, 0.03, 1)',
        f'shader_parameter/outline_width = {u["outline"]}',
        'shader_parameter/outline_max_pixels = 1.5', "",
        '[resource]',
        f'resource_name = "{uid}_body_material"',
        'next_pass = SubResource("ShaderMaterial_outline")',
        'shader = ExtResource("1_toon")',
        'shader_parameter/albedo_color = Color(1, 1, 1, 1)',
        'shader_parameter/albedo_texture = ExtResource("3_albedo")',
        f'shader_parameter/shadow_tint = {col(u["shadow"])}',
        'shader_parameter/light_threshold = 0.30',
        'shader_parameter/band_softness = 0.03',
        f'shader_parameter/light_energy = {u["light_energy"]}',
        'shader_parameter/light_response = 1.5',
        f'shader_parameter/rim_color = {col(u["rim"])}',
        f'shader_parameter/rim_strength = {u["rim_strength"]}',
        'shader_parameter/rim_power = 3.0',
        'shader_parameter/rim_threshold = 0.5',
        'shader_parameter/specular_color = Color(1, 0.86, 0.82, 1)',
        f'shader_parameter/specular_amount = {u["spec"]}',
        'shader_parameter/specular_gloss = 0.75',
        'shader_parameter/specular_threshold = 0.55',
        f'shader_parameter/use_normal_map = {"true" if u["normal"] else "false"}']
    if u["normal"]:
        lines.append('shader_parameter/normal_map_texture = ExtResource("5_normal")')
    lines += [f'shader_parameter/normal_map_depth = {u["normal_depth"]}',
        f'shader_parameter/emission_color = {col(u["emission"])}',
        f'shader_parameter/emission_energy = {u["emission_energy"]}',
        'shader_parameter/emission_mask = ExtResource("4_emission")',
        'shader_parameter/uv_scale = Vector2(1, 1)',
        'shader_parameter/uv_offset = Vector2(0, 0)', ""]
    return "\n".join(lines)


def scene(uid, u):
    src = f"{SRC}/{u['src']}"
    ext = ['[ext_resource type="Script" path="res://assets/models/allies_refined/FormationAllyRefined.gd" id="1_script"]']
    if u["anims"]:
        ext.append(f'[ext_resource type="AnimationLibrary" path="{DST}/{uid}/{uid}_anims.tres" id="2_anims"]')
    ext.append(f'[ext_resource type="Material" path="{DST}/{uid}/{uid}_flame_material.tres" id="3_flame"]')
    scales = ", ".join(f'"{k}": {v}' for k, v in u["scales"].items())
    node = [f'[node name="{"".join(w.capitalize() for w in uid.split("_"))}Refined" type="Node3D"]',
            'script = ExtResource("1_script")',
            f'idle_scene_path = "{src}/idle.fbx"',
            f'attack_scene_path = "{src}/attack.fbx"',
            f'run_scene_path = "{src}/run.fbx"',
            f'body_material_path = "{DST}/{uid}/{uid}_body_material.tres"',
            f'display_name = "{u["name"]}"',
            "action_scales = {%s}" % scales,
            "action_yaw_degrees = {%s}" % ", ".join(f'"{k}": {v}' for k, v in u.get("yaws", {}).items()),
            "action_lift = {%s}" % ", ".join(f'"{k}": {v}' for k, v in u.get("offsets", {}).items())]
    if u["anims"]:
        node.append('authored_animations = ExtResource("2_anims")')
    node.append("flame_points = " + gd_value(u["flames"]))
    node.append('flame_material = ExtResource("3_flame")')
    return "\n".join([f'[gd_scene load_steps={len(ext) + 5} format=3]', ""] + ext + ["",
        '[sub_resource type="Animation" id="Animation_idle"]', 'resource_name = "idle"', 'length = 1.0', 'loop_mode = 1', "",
        '[sub_resource type="Animation" id="Animation_attack"]', 'resource_name = "attack"', 'length = 1.0', "",
        '[sub_resource type="Animation" id="Animation_run"]', 'resource_name = "run"', 'length = 1.0', 'loop_mode = 1', "",
        '[sub_resource type="AnimationLibrary" id="AnimationLibrary_proxy"]',
        '_data = {', '&"attack": SubResource("Animation_attack"),', '&"idle": SubResource("Animation_idle"),',
        '&"run": SubResource("Animation_run")', '}', ""] + node + ["",
        '[node name="AnimationPlayer" type="AnimationPlayer" parent="."]',
        'libraries/ = SubResource("AnimationLibrary_proxy")', "",
        '[node name="ModelRoot" type="Node3D" parent="."]', ""])


def main():
    written = []
    for uid, u in UNITS.items():
        for kind in ("albedo", "emission"):
            path = f"{DST}/{uid}/{uid}_body_{kind}.png"
            imp = os.path.join(ROOT, path.replace("res://", "") + ".import")
            if not os.path.exists(imp):
                written.append(write(path + ".import", TEX_IMPORT.format(path=path)))
        written.append(write(f"{DST}/{uid}/{uid}_body_material.tres", material(uid, u)))
        written.append(write(f"{DST}/{uid}/{uid}_flame_material.tres", flame_material(uid, u)))
        written.append(write(f"{DST}/{uid}/{uid}_refined.tscn", scene(uid, u)))
    if APPLY_DATA:
        p = os.path.join(ROOT, "data/formation/formation_allies.json")
        raw = open(p, encoding="utf-8").read()
        data = json.loads(raw)
        for a in data["allies"]:
            if a["id"] in UNITS:
                new = f"{DST}/{a['id']}/{a['id']}_refined.tscn"
                raw = raw.replace(json.dumps(a["model"]), json.dumps(new), 1)
        open(p, "w", encoding="utf-8", newline="").write(raw)
        written.append(p)
    print("\n".join(written))


if __name__ == "__main__":
    main()
