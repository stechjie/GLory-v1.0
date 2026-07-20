extends VFXBlockRoot
class_name VFXSlashRing3D

const PATH_RIBBON := preload("res://effects/vfx3d/modules/VFXPathRibbon3D.gd")

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	play_ring(context.get("target", Vector3.ZERO), profile)

func play_ring(at: Vector3, profile: VFXProfile3D = null) -> void:
	begin()
	position = at + Vector3(0.0, 0.08, 0.0)
	var params: Dictionary = profile.parameters if profile != null else {}
	var radius := float(params.get("radius", 1.15)) * (profile.size if profile != null else 1.0)
	var duration := profile.duration if profile != null else 0.72
	var main_profile := profile.duplicate_runtime() if profile != null else _fallback_profile()
	main_profile.duration = duration * 0.76
	main_profile.parameters = main_profile.parameters.duplicate()
	main_profile.parameters["width"] = float(params.get("width", 0.24))
	main_profile.parameters["taper_both_ends"] = false
	main_profile.parameters["curve_bias"] = 0.28
	main_profile.parameters["reveal_ratio"] = 0.20
	main_profile.parameters["hold_ratio"] = 0.10
	var main_points := _build_ring(radius, 0.0, 30)
	var main_ribbon := PATH_RIBBON.new()
	add_child(main_ribbon)
	main_ribbon.play_path(main_points, Vector3.UP, main_profile)
	_spawn_radial_fragments(main_points, main_profile)
	await get_tree().create_timer(duration * 0.12).timeout
	if _finished:
		return
	var second_profile := main_profile.duplicate_runtime()
	second_profile.duration = duration * 0.52
	second_profile.size *= 0.92
	second_profile.main_color = main_profile.main_color.darkened(0.20)
	second_profile.core_color = main_profile.main_color.lightened(0.28)
	second_profile.emission_energy *= 0.68
	second_profile.parameters = second_profile.parameters.duplicate()
	second_profile.parameters["width"] = float(params.get("width", 0.24)) * 0.55
	second_profile.parameters["spark_count"] = 0
	var second_points := _build_ring(radius * 0.82, 0.06, 26)
	var second_ribbon := PATH_RIBBON.new()
	add_child(second_ribbon)
	second_ribbon.play_path(second_points, Vector3.UP, second_profile)
	await get_tree().create_timer(duration * 0.66).timeout
	finish()

func _build_ring(radius: float, height_wave: float, segments: int) -> PackedVector3Array:
	var points := PackedVector3Array()
	var sweep := TAU * (0.82 if segments >= 30 else 0.68)
	var start := deg_to_rad(205.0)
	for i in range(segments + 1):
		var t := float(i) / float(segments)
		var angle := start + sweep * t
		var irregular := 1.0 + sin(t * PI * 5.0) * 0.025
		points.append(Vector3(
			cos(angle) * radius * irregular,
			height_wave + sin(angle * 2.0) * radius * 0.035,
			sin(angle) * radius * irregular
		))
	return points

func _fallback_profile() -> VFXProfile3D:
	var profile := VFXProfile3D.new()
	profile.dark_color = Color(0.05, 0.015, 0.16)
	profile.main_color = Color(0.58, 0.12, 1.0)
	profile.core_color = Color(1.0, 0.62, 1.0)
	profile.emission_energy = 3.6
	profile.duration = 0.72
	return profile

func _spawn_radial_fragments(points: PackedVector3Array, source_profile: VFXProfile3D) -> void:
	var indices := [6, 12, 18, 24]
	for i in range(indices.size()):
		var index: int = mini(indices[i], points.size() - 2)
		var start := points[index]
		var radial := Vector3(start.x, 0.0, start.z).normalized()
		var tangent := (points[index + 1] - points[index - 1]).normalized()
		var direction := (radial + tangent * (-0.22 if i % 2 == 0 else 0.18)).normalized()
		var length := 0.32 + float(i) * 0.06
		var fragment_points := PackedVector3Array([
			start + Vector3.UP * 0.012,
			start + direction * length * 0.48 + Vector3.UP * 0.018,
			start + direction * length + Vector3.UP * 0.01,
		])
		var fragment_profile := source_profile.duplicate_runtime()
		fragment_profile.duration = 0.19 + float(i) * 0.016
		fragment_profile.emission_energy *= 0.82
		fragment_profile.parameters = {
			"width": 0.078 + float(i % 2) * 0.016,
			"halo_width": 1.28,
			"taper_both_ends": false,
			"curve_bias": 0.35,
			"reveal_ratio": 0.12,
			"hold_ratio": 0.04,
			"spark_count": 0,
		}
		var fragment := PATH_RIBBON.new()
		add_child(fragment)
		fragment.play_path(fragment_points, Vector3.UP, fragment_profile)
