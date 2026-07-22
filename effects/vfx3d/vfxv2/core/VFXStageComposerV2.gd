extends Node3D
class_name VFXStageComposerV2

const BINBUN := preload("res://effects/vfx3d/vfxv2/VFXBinbunReference3D.gd")
const EXTERNAL := preload("res://effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd")
const PAINTED := preload("res://effects/vfx3d/modules/VFXBossTextureLayer3D.gd")

var recipe: VFXRecipeV2
var origin := Vector3.ZERO
var target := Vector3.ZERO
var profile: VFXProfile3D

func play_recipe(value: VFXRecipeV2, data: Dictionary = {}) -> void:
	recipe = value
	origin = data.get("origin", global_position)
	target = data.get("target", origin + Vector3.FORWARD * 2.0)
	profile = data.get("profile", _default_profile())
	for i in range(recipe.stage_count()):
		var stage_id := recipe.stage_ids[i]
		var start := recipe.stage_starts[i] if i < recipe.stage_starts.size() else 0.0
		var stage_duration := recipe.stage_durations[i] if i < recipe.stage_durations.size() else 0.5
		var timer := create_tween()
		timer.tween_interval(start)
		timer.tween_callback(Callable(self, "_spawn_stage").bind(stage_id, stage_duration))
	_finish_after(_recipe_end())

func _spawn_stage(stage_id: String, stage_duration: float) -> void:
	match stage_id:
		"binbun_projectile", "binbun_projectile_repeat":
			var projectile := BINBUN.new()
			add_child(projectile)
			projectile.play_reference("projectile", origin, target, profile)
		"painted_silence":
			_spawn_painted_projectile("res://assets/vfx/skills/dark_mage/dark_mage_magic_bolt.png", origin, target, profile, Vector2(.72, .22), Color(.035, .008, .08), Color(.34, .08, .72), Color(.86, .68, 1.0), 2.8)
		"painted_poison":
			_spawn_painted_projectile("res://assets/vfx/skills/undead_spike/undead_spike_bone_dart.png", origin, target, profile, Vector2(.72, .24), Color(.02, .07, .01), Color(.24, .70, .06), Color(.78, 1.0, .22), 4.6)
		"painted_meteor":
			_spawn_painted_projectile("res://assets/vfx/boss/boss_meteor_trail.png", origin, target, profile, Vector2(.86, .38), Color(.10, .012, .002), Color(.86, .12, .01), Color(1.0, .82, .28), 7.1)
		"binbun_slash":
			var slash := BINBUN.new()
			add_child(slash)
			slash.play_reference("slash", target, target, profile)
		"binbun_loot", "binbun_loot_burst":
			var loot := BINBUN.new()
			add_child(loot)
			loot.play_reference("loot", target, target, profile)
		"binbun_area":
			var area := BINBUN.new()
			add_child(area)
			area.play_reference("area", target, target, profile)
		"binbun_portal":
			var portal := BINBUN.new()
			add_child(portal)
			portal.play_reference("portal", target, target, profile)
		"binbun_beam":
			var beam := BINBUN.new()
			add_child(beam)
			beam.play_reference("beam", origin, target, profile)
		"external_orb", "external_muzzle", "external_hit", "external_explosion", "external_smoke":
			var external := EXTERNAL.new()
			add_child(external)
			var external_kind: String = str({
				"external_orb": "demo_orb_03",
				"external_muzzle": "starter_muzzle",
				"external_hit": "starter_hit_02",
				"external_explosion": "starter_explosion",
				"external_smoke": "starter_smoke_01"
			}.get(stage_id, "starter_hit_02"))
			external.play_external(external_kind, target if stage_id != "external_muzzle" else origin, target, profile)

func _default_profile() -> VFXProfile3D:
	var p := VFXProfile3D.new()
	p.main_color = Color(0.18, 0.62, 1.0)
	p.core_color = Color(0.82, 0.98, 1.0)
	p.dark_color = Color(0.02, 0.05, 0.18)
	p.size = 1.1
	p.duration = 0.7
	p.emission_energy = 4.6
	p.particle_count = 32
	return p

func _spawn_painted_projectile(texture_path: String, from: Vector3, to: Vector3, palette: VFXProfile3D, size: Vector2, dark: Color, body: Color, core: Color, seed: float) -> void:
	var layer := PAINTED.new()
	add_child(layer)
	layer.play_layer(texture_path, {"from": from, "to": to, "size": size, "duration": .78, "travel_ratio": .72, "dark_tint": dark, "body_tint": body, "core_tint": core, "seed": seed, "flow_strength": .024, "opacity": 1.0})

func _recipe_end() -> float:
	var end := 1.0
	for i in range(recipe.stage_count()):
		var start := recipe.stage_starts[i] if i < recipe.stage_starts.size() else 0.0
		var duration := recipe.stage_durations[i] if i < recipe.stage_durations.size() else 0.5
		end = maxf(end, start + duration)
	return end + 0.35

func _finish_after(seconds: float) -> void:
	get_tree().create_timer(seconds).timeout.connect(queue_free)
