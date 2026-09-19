class_name WorldVisualStyle
extends Resource

const PROFILE_PATH := "res://data/presentation/model_visual_profiles.json"
const CHARACTER_OUTLINE_PATH := "res://shaders/character_outline.gdshader"
const CONTACT_SHADOW_SHADER := preload("res://shaders/world_contact_shadow.gdshader")

@export_group("World Lighting")
@export var key_color := Color(1.0, 0.92, 0.76)
@export var key_energy := 0.64
@export var key_rotation_degrees := Vector3(-52.0, -28.0, 0.0)
@export var fill_color := Color(0.48, 0.68, 0.82)
@export var fill_energy := 0.18
@export var fill_rotation_degrees := Vector3(-38.0, 142.0, 0.0)
@export var ambient_color := Color(0.58, 0.68, 0.61)
@export var ambient_energy := 0.40

@export_group("Readability")
@export var outline_color := Color(0.035, 0.026, 0.055, 1.0)
@export var normal_outline_px := 1.5
@export var large_outline_px := 2.4
@export var contact_shadow_color := Color(0.025, 0.03, 0.026, 0.34)

var _profiles: Dictionary = {}


func configure_world(parent: Node, prefix: String, background_color: Color, transparent_background: bool = false) -> Dictionary:
	var environment_node := WorldEnvironment.new()
	environment_node.name = "%sEnvironment" % prefix
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(background_color.r, background_color.g, background_color.b, 0.0 if transparent_background else background_color.a)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = ambient_color
	environment.ambient_light_energy = ambient_energy
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment_node.environment = environment
	parent.add_child(environment_node)

	var key_light := DirectionalLight3D.new()
	key_light.name = "%sKeyLight" % prefix
	key_light.light_color = key_color
	key_light.light_energy = key_energy
	key_light.rotation_degrees = key_rotation_degrees
	key_light.shadow_enabled = false
	parent.add_child(key_light)

	var fill_light := DirectionalLight3D.new()
	fill_light.name = "%sFillLight" % prefix
	fill_light.light_color = fill_color
	fill_light.light_energy = fill_energy
	fill_light.rotation_degrees = fill_rotation_degrees
	fill_light.shadow_enabled = false
	parent.add_child(fill_light)
	return {"environment": environment_node, "key": key_light, "fill": fill_light}


func configure_existing(environment_node: WorldEnvironment, key_light: DirectionalLight3D, fill_light: Light3D) -> void:
	if environment_node != null:
		var environment := environment_node.environment
		if environment == null:
			environment = Environment.new()
			environment_node.environment = environment
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		environment.ambient_light_color = ambient_color
		environment.ambient_light_energy = ambient_energy
		environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	if key_light != null:
		key_light.light_color = key_color
		key_light.light_energy = key_energy
		key_light.rotation_degrees = key_rotation_degrees
		key_light.shadow_enabled = false
	var configured_fill := fill_light
	if fill_light != null and not (fill_light is DirectionalLight3D):
		var fill_parent := fill_light.get_parent()
		var fill_name := fill_light.name
		fill_light.free()
		configured_fill = DirectionalLight3D.new()
		configured_fill.name = fill_name
		fill_parent.add_child(configured_fill)
	if configured_fill != null:
		configured_fill.light_color = fill_color
		configured_fill.light_energy = fill_energy
		(configured_fill as DirectionalLight3D).rotation_degrees = fill_rotation_degrees
		configured_fill.shadow_enabled = false


func make_contact_shadow(node_name: String, size: Vector2, position: Vector3) -> MeshInstance3D:
	var mesh := PlaneMesh.new()
	mesh.size = size
	var material := ShaderMaterial.new()
	material.shader = CONTACT_SHADOW_SHADER
	material.set_shader_parameter("shadow_color", contact_shadow_color)
	mesh.material = material
	var shadow := MeshInstance3D.new()
	shadow.name = node_name
	shadow.mesh = mesh
	shadow.position = position
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return shadow


func outline_width_for(profile_id: String, fallback_large: bool = false) -> float:
	var profile := _profile_for(profile_id)
	if not bool(profile.get("pilot_enabled", false)):
		return 0.0
	return float(profile.get("outline_px", large_outline_px if fallback_large else normal_outline_px))


func apply_model_profile(root: Node3D, profile_id: String, fallback_large: bool = false) -> int:
	var width_px := outline_width_for(profile_id, fallback_large)
	if width_px <= 0.0 or root == null:
		return 0
	var changed := 0
	for found in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := found as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		if mesh_instance.material_override != null:
			var replacement := _profiled_material(mesh_instance.material_override, width_px)
			if replacement != null:
				mesh_instance.material_override = replacement
				changed += 1
			continue
		for surface_index in mesh_instance.mesh.get_surface_count():
			var active := mesh_instance.get_active_material(surface_index)
			var replacement := _profiled_material(active, width_px)
			if replacement != null:
				mesh_instance.set_surface_override_material(surface_index, replacement)
				changed += 1
	return changed


func _profiled_material(source: Material, width_px: float) -> Material:
	if source == null or source.next_pass == null or not (source.next_pass is ShaderMaterial):
		return null
	var outline := source.next_pass as ShaderMaterial
	if outline.shader == null or outline.shader.resource_path != CHARACTER_OUTLINE_PATH:
		return null
	var material_copy := source.duplicate(false) as Material
	var outline_copy := outline.duplicate(false) as ShaderMaterial
	if material_copy == null or outline_copy == null:
		return null
	outline_copy.set_shader_parameter("use_screen_space", true)
	outline_copy.set_shader_parameter("outline_width_px", width_px)
	outline_copy.set_shader_parameter("outline_color", outline_color)
	material_copy.next_pass = outline_copy
	return material_copy


func _profile_for(profile_id: String) -> Dictionary:
	if _profiles.is_empty():
		_load_profiles()
	return _profiles.get(profile_id, {}) as Dictionary


func _load_profiles() -> void:
	if not FileAccess.file_exists(PROFILE_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PROFILE_PATH))
	if parsed is Dictionary:
		_profiles = (parsed as Dictionary).get("profiles", {}) as Dictionary
