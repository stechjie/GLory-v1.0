extends VFXBlockRoot
class_name VFXCameraFeedback3D

const CURVES := preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")

var _camera: Camera3D
var _base_position := Vector3.ZERO
var _base_fov := 0.0
var _elapsed := 0.0
var _duration := 0.28
var _strength := 0.055
var _zoom_kick := 0.8

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	var camera := context.get("camera") as Camera3D
	play_feedback(camera, profile)

func play_feedback(camera: Camera3D, profile: VFXProfile3D = null) -> void:
	begin()
	if camera == null:
		finish()
		return
	var params: Dictionary = profile.parameters if profile != null else {}
	_camera = camera
	_base_position = camera.position
	_base_fov = camera.fov
	_duration = profile.duration if profile != null else 0.28
	_strength = float(params.get("shake", 0.055))
	_zoom_kick = float(params.get("zoom_kick", 0.8))
	_elapsed = 0.0
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)
	await get_tree().create_timer(_duration, true, false, true).timeout
	_restore_camera()
	finish()

func _process(delta: float) -> void:
	if _camera == null or not is_instance_valid(_camera):
		return
	_elapsed += delta
	var t := clampf(_elapsed / maxf(_duration, 0.01), 0.0, 1.0)
	var envelope := 1.0 - CURVES.sample("explosive_out", t)
	var shake := Vector3(sin(_elapsed * 91.0), cos(_elapsed * 73.0) * 0.55, 0.0) * _strength * envelope
	_camera.position = _base_position + shake
	_camera.fov = _base_fov - sin(t * PI) * _zoom_kick

func _restore_camera() -> void:
	if _camera != null and is_instance_valid(_camera):
		_camera.position = _base_position
		_camera.fov = _base_fov
	_camera = null

func _exit_tree() -> void:
	_restore_camera()
