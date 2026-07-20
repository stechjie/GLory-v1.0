extends VFXBlockRoot
class_name VFXLightPulse3D

const QUALITY := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")
const CURVES := preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")

var _light: OmniLight3D
var _peak_energy := 3.5

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	play_pulse(context.get("target", Vector3.ZERO), profile)

func play_pulse(at: Vector3, profile: VFXProfile3D = null) -> void:
	begin()
	if not QUALITY.allow_dynamic_light():
		finish(0.02)
		return
	var params: Dictionary = profile.parameters if profile != null else {}
	position = at + Vector3(0.0, float(params.get("height", 0.34)), 0.0)
	_light = OmniLight3D.new()
	_light.name = "VFXLightPulse"
	_light.light_color = profile.core_color if profile != null else Color(1.0, 0.55, 0.12)
	_peak_energy = float(params.get("energy", profile.emission_energy if profile != null else 3.5))
	_light.light_energy = 0.0
	_light.omni_range = float(params.get("range", (profile.size if profile != null else 1.0) * 2.2))
	_light.shadow_enabled = false
	add_child(_light)
	var duration := profile.duration if profile != null else 0.36
	CURVES.tween_method(self, _set_pulse, 0.0, 1.0, duration, "pulse")
	await get_tree().create_timer(duration + 0.04).timeout
	finish()

func _set_pulse(value: float) -> void:
	if _light != null:
		_light.light_energy = _peak_energy * value * vfx_alpha

func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	if _light != null:
		_light.light_energy = _peak_energy * vfx_alpha
