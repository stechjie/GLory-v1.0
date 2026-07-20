extends VFXBlockRoot
class_name VFXHitStopController

var _previous_scale := 1.0
var _active := false

func play_profile(profile: VFXProfile3D, _context: Dictionary) -> void:
	var params: Dictionary = profile.parameters if profile != null else {}
	play_hit_stop(profile.duration if profile != null else 0.075, float(params.get("time_scale", 0.08)))

func play_hit_stop(duration := 0.075, reduced_scale := 0.08) -> void:
	begin()
	process_mode = Node.PROCESS_MODE_ALWAYS
	_previous_scale = Engine.time_scale
	_active = true
	Engine.time_scale = clampf(reduced_scale, 0.01, 1.0)
	await get_tree().create_timer(duration, true, false, true).timeout
	_restore_time_scale()
	finish()

func _restore_time_scale() -> void:
	if _active:
		Engine.time_scale = _previous_scale
		_active = false

func _exit_tree() -> void:
	_restore_time_scale()
