extends VFXBlockRoot
class_name VFXComposition3D

const CURVES := preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")

var layers: Array[Node3D] = []
var _triggered_tracks: Dictionary = {}

func add_layer(layer: Node3D, layer_name := "") -> Node3D:
	if layer == null:
		return null
	if not layer_name.is_empty():
		layer.name = layer_name
	add_child(layer)
	layers.append(layer)
	return layer

func play_recipe(recipe: Resource, context: Dictionary = {}) -> void:
	begin()
	if recipe == null or recipe.get("tracks") == null:
		finish()
		return
	var total_duration := 0.0
	for index in range(recipe.tracks.size()):
		var track: Resource = recipe.tracks[index]
		if track == null:
			continue
		total_duration = maxf(total_duration, float(track.start_time) + float(track.duration) / maxf(float(track.time_scale), 0.01))
		_run_track(track, context, index)
	await get_tree().create_timer(total_duration + 0.18).timeout
	finish()

func _run_track(track: Resource, context: Dictionary, index: int) -> void:
	var key := "%s:%d" % [str(track.track_id), index]
	if bool(track.trigger_once) and _triggered_tracks.has(key):
		return
	if bool(track.trigger_once):
		_triggered_tracks[key] = true
	await get_tree().create_timer(maxf(float(track.start_time), 0.0)).timeout
	if _finished or track.module_script == null:
		return
	var scaled_duration: float = float(track.duration) / maxf(float(track.time_scale), 0.01)
	var repeat_duration := scaled_duration
	if bool(track.loop) and track.profile != null:
		repeat_duration = minf(float(track.profile.duration) / maxf(float(track.time_scale), 0.01), scaled_duration)
	var elapsed := 0.0
	var repeat_index := 0
	while elapsed < scaled_duration - 0.001:
		if _finished:
			return
		var layer := track.module_script.new() as Node3D
		if layer == null:
			return
		add_layer(layer, "%s_%d" % [str(track.track_id), repeat_index])
		if layer.has_method("set_vfx_alpha"):
			layer.call("set_vfx_alpha", 0.0 if float(track.fade_in) > 0.0 else 1.0)
		var current_duration := minf(repeat_duration, scaled_duration - elapsed)
		var runtime_profile: VFXProfile3D = track.profile
		if runtime_profile != null:
			runtime_profile = runtime_profile.duplicate_runtime()
			runtime_profile.duration = minf(runtime_profile.duration / maxf(float(track.time_scale), 0.01), current_duration)
		if layer.has_method("play_profile"):
			layer.call("play_profile", runtime_profile, context)
		_animate_track(layer, track, current_duration)
		await get_tree().create_timer(current_duration).timeout
		if is_instance_valid(layer):
			layer.queue_free()
		elapsed += current_duration
		repeat_index += 1
		if not bool(track.loop):
			break

func _animate_track(layer: Node3D, track: Resource, scaled_duration: float) -> void:
	var fade_in: float = minf(float(track.fade_in), scaled_duration)
	var fade_out: float = minf(float(track.fade_out), scaled_duration)
	if layer.has_method("set_vfx_alpha") and fade_in > 0.0:
		CURVES.tween_method(self, Callable(layer, "set_vfx_alpha"), 0.0, 1.0, fade_in, "explosive_out")
	if layer.has_method("set_vfx_alpha") and fade_out > 0.0:
		var delay := maxf(0.0, scaled_duration - fade_out)
		var tween := create_tween()
		tween.tween_interval(delay)
		tween.tween_method(Callable(layer, "set_vfx_alpha"), 1.0, 0.0, fade_out).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)

func clear_layers() -> void:
	for layer in layers:
		if layer != null and is_instance_valid(layer):
			layer.queue_free()
	layers.clear()
