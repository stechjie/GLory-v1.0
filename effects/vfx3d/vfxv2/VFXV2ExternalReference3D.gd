extends VFXBlockRoot
class_name VFXV2ExternalReference3D

const ROOT := "res://effects/vfx3d/vfxv2/reference_packages/"
const SCENES := {
	"starter_hit_01": ROOT + "Starter_Vfx/scenes/hit_impact/vfx_hit_impact_01.tscn",
	"starter_hit_02": ROOT + "Starter_Vfx/scenes/hit_impact/vfx_hit_impact_02.tscn",
	"starter_fire": ROOT + "Starter_Vfx/scenes/fire/vfx_fire_01.tscn",
	"starter_explosion": ROOT + "Starter_Vfx/scenes/explosion/vfx_air_explosion_01.tscn",
	"starter_smoke_01": ROOT + "Starter_Vfx/scenes/movement/vfx_ground_smoke_01.tscn",
	"starter_smoke_02": ROOT + "Starter_Vfx/scenes/movement/vfx_ground_smoke_02.tscn",
	"starter_muzzle": ROOT + "Starter_Vfx/scenes/muzzle/vfx_muzzle_01.tscn",
	"starter_loot_01": ROOT + "Starter_Vfx/scenes/loot/vfx_loot_environment_01.tscn",
	"starter_loot_02": ROOT + "Starter_Vfx/scenes/loot/vfx_loot_environment_02.tscn",
	"demo_orb_03": ROOT + "Demo_GodotVFX/GodotVFX/effects/magic_orb_flash/magic_orb_flash_vfx_03.tscn",
	"demo_orb_04": ROOT + "Demo_GodotVFX/GodotVFX/effects/magic_orb_flash/magic_orb_flash_vfx_04.tscn"
}

var reference_instance: Node3D

func play_external(kind: String, origin: Vector3, _target: Vector3, profile: VFXProfile3D) -> void:
	var path: String = SCENES.get(kind, "")
	if path.is_empty():
		return
	# 同 VFXBinbunReference3D：改走共享缓存，不在施法帧同步读盘。
	var t0 := Time.get_ticks_usec()
	var packed := VFXExternalCache.get_scene(path)
	var load_us := Time.get_ticks_usec() - t0
	if load_us > 30000:
		print("[EXTVFX] starter/%s  取场景=%.0fms" % [kind, load_us / 1000.0])
	if packed == null:
		push_error("External VFX reference failed to load: %s" % path)
		return
	reference_instance = packed.instantiate() as Node3D
	if reference_instance == null:
		return
	reference_instance.name = "ExternalReference_%s" % kind
	add_child(reference_instance)
	reference_instance.global_position = origin
	_apply_profile(profile)
	_force_play()
	_finish_after(3.2)

func _apply_profile(profile: VFXProfile3D) -> void:
	if reference_instance == null or profile == null:
		return
	for key in ["primary_color", "main_color"]:
		if reference_instance.get(key) != null:
			reference_instance.set(key, profile.main_color)
	for key in ["secondary_color", "core_color"]:
		if reference_instance.get(key) != null:
			reference_instance.set(key, profile.core_color)
	for key in ["tertiary_color", "dark_color"]:
		if reference_instance.get(key) != null:
			reference_instance.set(key, profile.dark_color)
	if reference_instance.get("emission") != null:
		reference_instance.set("emission", profile.emission_energy)
	if reference_instance.get("vfx_scale") != null:
		reference_instance.set("vfx_scale", maxf(profile.size, 0.8))
	if reference_instance.get("speed_scale") != null:
		reference_instance.set("speed_scale", 1.0)

func _force_play() -> void:
	if reference_instance == null:
		return
	if reference_instance.has_method("play"):
		reference_instance.call_deferred("play")
	elif reference_instance.has_method("restart_vfx"):
		reference_instance.call_deferred("restart_vfx")
	for node in _walk_nodes(reference_instance):
		if node is GPUParticles3D:
			(node as GPUParticles3D).restart()

func _walk_nodes(root: Node) -> Array[Node]:
	var result: Array[Node] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		result.append(node)
		for child in node.get_children():
			stack.append(child)
	return result

func _finish_after(seconds: float) -> void:
	get_tree().create_timer(seconds).timeout.connect(queue_free)
