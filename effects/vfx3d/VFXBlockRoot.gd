extends Node3D
class_name VFXBlockRoot

var _tweens: Array[Tween] = []
var _finished := false
var vfx_alpha := 1.0
var vfx_brightness := 1.0

func begin() -> void:
	_finished = false
	visible = true

func track_tween(tween: Tween) -> Tween:
	if tween != null:
		_tweens.append(tween)
	return tween

func set_vfx_alpha(value: float) -> void:
	vfx_alpha = clampf(value, 0.0, 1.0)
	visible = vfx_alpha > 0.001

func set_vfx_brightness(value: float) -> void:
	vfx_brightness = maxf(value, 0.0)

func stop_vfx(immediate := false) -> void:
	if immediate:
		finish()
	else:
		var tween := track_tween(create_tween())
		tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_method(set_vfx_alpha, vfx_alpha, 0.0, 0.12)
		tween.tween_callback(finish)

func finish(delay := 0.0) -> void:
	if _finished:
		return
	_finished = true
	for tween in _tweens:
		if tween != null and tween.is_valid():
			tween.kill()
	_tweens.clear()
	if delay <= 0.0:
		queue_free()
	else:
		await get_tree().create_timer(delay).timeout
		if is_instance_valid(self):
			queue_free()
