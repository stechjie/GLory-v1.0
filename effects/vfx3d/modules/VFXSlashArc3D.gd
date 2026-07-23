extends VFXBlockRoot
class_name VFXSlashArc3D

const PATH_RIBBON := preload("res://effects/vfx3d/modules/VFXPathRibbon3D.gd")

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	play_slash(context.get("target", Vector3.ZERO), context.get("direction", Vector3.RIGHT), profile)

func play_slash(at: Vector3, direction: Vector3, profile: VFXProfile3D = null) -> void:
	begin()
	position = at
	var params: Dictionary = profile.parameters if profile != null else {}
	var radius := float(params.get("radius", 1.15)) * (profile.size if profile != null else 1.0)
	var angle_degrees := float(params.get("arc_degrees", 128.0))
	var tilt_degrees := float(params.get("tilt_degrees", 18.0))
	var duration := profile.duration if profile != null else 0.58
	var facing := direction.normalized()
	if facing.length_squared() < 0.001:
		facing = Vector3.RIGHT
	var points := _build_vertical_arc(radius, angle_degrees, tilt_degrees, facing)
	var main_profile := profile.duplicate_runtime() if profile != null else _fallback_profile()
	main_profile.duration = duration * 0.72
	main_profile.parameters = main_profile.parameters.duplicate()
	main_profile.parameters["width"] = float(params.get("width", 0.16))
	main_profile.parameters["taper_both_ends"] = false
	main_profile.parameters["curve_bias"] = 0.44
	main_profile.parameters["reveal_ratio"] = 0.18
	main_profile.parameters["hold_ratio"] = 0.10
	var ribbon := PATH_RIBBON.new()
	add_child(ribbon)
	ribbon.play_path(points, Vector3.FORWARD, main_profile)
	await get_tree().create_timer(duration * 0.075).timeout
	if _finished:
		return
	var echo_profile := main_profile.duplicate_runtime()
	echo_profile.duration = duration * 0.52
	echo_profile.size *= 1.08
	echo_profile.main_color = main_profile.main_color.darkened(0.24)
	echo_profile.core_color = main_profile.main_color.lightened(0.18)
	echo_profile.emission_energy *= 0.42
	echo_profile.parameters = echo_profile.parameters.duplicate()
	echo_profile.parameters["width"] = float(params.get("width", 0.16)) * 0.42
	echo_profile.parameters["spark_count"] = 0
	var echo := PATH_RIBBON.new()
	echo.position = Vector3(0.0, -0.04, 0.025)
	add_child(echo)
	echo.play_path(points, Vector3.FORWARD, echo_profile)
	await get_tree().create_timer(duration * 0.70).timeout
	finish()

func _build_vertical_arc(radius: float, degrees: float, tilt_degrees: float, direction: Vector3) -> PackedVector3Array:
	var points := PackedVector3Array()
	var segments := 22
	var start := deg_to_rad(180.0 + degrees * 0.5)
	var sweep := deg_to_rad(degrees)
	var sign_x := 1.0 if direction.x >= 0.0 else -1.0
	var tilt := deg_to_rad(tilt_degrees) * sign_x
	for i in range(segments + 1):
		var t := float(i) / float(segments)
		var angle := start - sweep * t
		var x := cos(angle) * radius * sign_x
		var y := sin(angle) * radius
		var rotated_x := x * cos(tilt) - y * sin(tilt)
		var rotated_y := x * sin(tilt) + y * cos(tilt)
		var irregular := sin(t * PI * 3.0) * radius * 0.025
		points.append(Vector3(rotated_x, rotated_y + radius * 0.22 + irregular, 0.0))
	return points

func _fallback_profile() -> VFXProfile3D:
	var profile := VFXProfile3D.new()
	profile.dark_color = Color(0.12, 0.025, 0.015)
	profile.main_color = Color(1.0, 0.31, 0.055)
	profile.core_color = Color(1.0, 0.88, 0.46)
	profile.emission_energy = 3.8
	profile.duration = 0.58
	return profile
