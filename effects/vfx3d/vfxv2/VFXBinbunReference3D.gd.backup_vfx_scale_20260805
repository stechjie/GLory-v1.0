extends VFXBlockRoot
class_name VFXBinbunReference3D

const ROOT := "res://effects/vfx3d/vfxv2/binbun_reference/assets/"
const SCENES := {
	"projectile": ROOT + "BinbunVFX_Vol2/ElementalMagicFX/effects/projectile/vfx_fire_projectile_01.tscn",
	"area": ROOT + "BinbunVFX_Vol2/ElementalMagicFX/effects/area/vfx_fire_area_01.tscn",
	"beam": ROOT + "BinbunVFX/beam_vfx/effects/base/base_beam_vfx.tscn",
	"portal": ROOT + "BinbunVFX/portal_vfx/effects/simple/simple_portal_vfx.tscn",
	"loot": ROOT + "BinbunVFX/loot_effects/effects/floating/loot_vfx_mythic.tscn",
	"slash": ROOT + "BinbunVFX_Vol2/BattleFX/effects/slash/vfx_blank_slash.tscn"
}

var reference_instance: Node3D
var endpoint: Node3D
var _beam_parameters: Dictionary = {}

func play_reference(kind: String, origin: Vector3, target: Vector3, profile: VFXProfile3D) -> void:
	var scene_path: String = SCENES.get(kind, "")
	if scene_path.is_empty():
		return
	# 走共享缓存：原本这里是裸 load()，在施法帧同步读盘 + 反序列化，
	# 真机实测 Boss 大圈那一下主线程冻结 5.9 秒；而且播完引用归零就卸载，下次再来一遍。
	var t0 := Time.get_ticks_usec()
	var packed := VFXExternalCache.get_scene(scene_path)
	var load_us := Time.get_ticks_usec() - t0
	if packed == null:
		push_error("Binbun reference scene failed to load: %s" % scene_path)
		return
	var t1 := Time.get_ticks_usec()
	reference_instance = packed.instantiate() as Node3D
	var inst_us := Time.get_ticks_usec() - t1
	# 埋点：5.9 秒到底落在取场景、实例化还是首帧绘制（shader 编译），
	# 光靠计数猜过两次都猜错了。只在明显偏慢时打，正常帧不刷屏。
	if load_us + inst_us > 30000:
		print("[EXTVFX] binbun/%s  取场景=%.0fms 实例化=%.0fms" % [
			kind, load_us / 1000.0, inst_us / 1000.0])
	reference_instance.name = "BinbunOriginal_%s" % kind
	add_child(reference_instance)
	reference_instance.global_position = origin
	_apply_palette(profile)
	call_deferred("_force_visible", kind)
	if kind == "beam":
		endpoint = Node3D.new()
		endpoint.name = "BinbunTargetEndpoint"
		get_parent().add_child(endpoint)
		endpoint.global_position = target
		reference_instance.set("end_point", endpoint)
		reference_instance.set("preview", true)
		# Allow a skill profile to opt out of the large endpoint burst without
		# changing the authored Binbun scene or affecting other beam skills.
		var beam_params:Dictionary = profile.parameters if profile != null else {}
		_beam_parameters = beam_params.duplicate()
		if beam_params.has("beam_radius"):
			reference_instance.set("beam_radius", float(beam_params["beam_radius"]))
		if beam_params.has("start_radius"):
			reference_instance.set("start_radius", float(beam_params["start_radius"]))
		if beam_params.has("enable_end"):
			reference_instance.set("enable_end", bool(beam_params["enable_end"]))
		if beam_params.has("end_emitting"):
			reference_instance.set("end_emitting", bool(beam_params["end_emitting"]))
	if reference_instance.has_method("open"):
		reference_instance.call("open")
	if reference_instance.get("emitting") != null:
		reference_instance.set("emitting", true)
	if kind == "projectile":
		var travel := create_tween()
		travel.tween_property(reference_instance, "global_position", target, 0.72).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		travel.tween_callback(func(): _trigger_close())
	elif kind == "slash":
		reference_instance.rotation_degrees.y = -18.0
		var slash_tween := create_tween()
		slash_tween.tween_property(reference_instance, "scale", Vector3.ONE * 1.22, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		slash_tween.tween_callback(func(): _trigger_close())
	_finish_after(2.4)

func _force_visible(kind: String) -> void:
	if reference_instance == null or not is_instance_valid(reference_instance):
		return
	if kind == "beam":
		reference_instance.set("preview", true)
		reference_instance.set("open_amount", 1.0)
		reference_instance.set("start_emitting", true)
		reference_instance.set("end_emitting", bool(_beam_parameters.get("end_emitting", true)))
		reference_instance.set("beam_radius", float(_beam_parameters.get("beam_radius", 0.28)))
		reference_instance.set("start_radius", float(_beam_parameters.get("start_radius", 0.3)))
	if _beam_parameters.has("enable_end"):
		reference_instance.set("enable_end", bool(_beam_parameters["enable_end"]))
	if kind == "portal":
		reference_instance.rotation_degrees.x = -90.0
		reference_instance.set("portal_mode", 0)
		reference_instance.set("open_amount", 1.0)
		reference_instance.set("size", Vector2(1.8, 1.8))
		reference_instance.set("emitting", true)
	if kind == "area":
		reference_instance.set("emitting", true)
	if kind == "loot":
		reference_instance.scale = Vector3.ONE * 1.8
		reference_instance.set("emitting", true)
		reference_instance.set("amount", 40)

func _apply_palette(profile: VFXProfile3D) -> void:
	if reference_instance == null:
		return
	var values := {"primary_color": profile.main_color, "secondary_color": profile.core_color, "tertiary_color": profile.dark_color, "emission": profile.emission_energy}
	for key in values:
		if reference_instance.get(key) != null:
			reference_instance.set(key, values[key])

func _trigger_close() -> void:
	if reference_instance != null and is_instance_valid(reference_instance) and reference_instance.has_method("close"):
		reference_instance.call("close")

func _finish_after(seconds: float) -> void:
	get_tree().create_timer(seconds).timeout.connect(queue_free)

func _exit_tree() -> void:
	# 基类在 _exit_tree 里维护全局并发计数，不能吞掉。
	super._exit_tree()
	if endpoint != null and is_instance_valid(endpoint):
		endpoint.queue_free()
